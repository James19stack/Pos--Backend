defmodule Pos.Catalog.Import do
  @moduledoc """
  CSV price-list import. All-or-nothing: every row is checked first, and if any row is
  bad nothing is written and each problem is reported with its row number.

  Columns: sku, name, price, vat_code (required); barcode (several separated by |),
  cost, weighed (yes/no), unit, reorder_level, category (must exist), opening_stock (new products only).
  Prices are in shillings, e.g. 190.00. A product that already exists (same sku) is
  updated, its price changes are audited, and its stock is never touched.
  """
  import Ecto.Query, warn: false

  alias NimbleCSV.RFC4180, as: CSV
  alias Pos.Catalog.{Barcode, Category, Product, VatRate}
  alias Pos.{Catalog, Inventory, Repo}

  @required ~w(sku name price vat_code)

  def run(user, csv_text, opts \\ []) do
    with {:ok, rows} <- parse(csv_text),
         {:ok, plan} <- plan(rows) do
      if Keyword.get(opts, :dry_run, false), do: {:ok, summary(plan, true)}, else: apply_plan(user, plan)
    end
  end

  ## Parsing

  defp parse(text) when is_binary(text) do
    case text |> String.trim_leading("\uFEFF") |> CSV.parse_string(skip_headers: false) do
      [header | rows] ->
        keys = Enum.map(header, &(&1 |> String.trim() |> String.downcase()))

        case @required -- keys do
          [] ->
            parsed =
              rows
              |> Enum.with_index(2)
              |> Enum.reject(fn {cells, _} -> Enum.all?(cells, &(String.trim(&1) == "")) end)
              |> Enum.map(fn {cells, line} -> {line, keys |> Enum.zip(cells) |> Map.new()} end)

            if parsed == [], do: {:error, %{errors: [%{row: nil, error: "The file has no products"}]}}, else: {:ok, parsed}

          missing ->
            {:error, %{errors: [%{row: 1, error: "Missing column(s): " <> Enum.join(missing, ", ")}]}}
        end

      _ ->
        {:error, %{errors: [%{row: nil, error: "The file is empty"}]}}
    end
  rescue
    NimbleCSV.ParseError -> {:error, %{errors: [%{row: nil, error: "Not a valid CSV file"}]}}
  end

  defp parse(_), do: {:error, %{errors: [%{row: nil, error: "No CSV text was sent"}]}}

  ## Planning (reads only)

  defp plan(rows) do
    skus = Enum.map(rows, fn {_, r} -> value(r, "sku") end)
    codes = rows |> Enum.flat_map(fn {_, r} -> barcodes(r) end)

    ctx = %{
      vat: VatRate |> Repo.all() |> Map.new(&{String.upcase(&1.code), &1}),
      categories: Category |> Repo.all() |> Map.new(&{String.downcase(&1.name), &1}),
      existing: Repo.all(from p in Product, where: p.sku in ^skus) |> Map.new(&{&1.sku, &1}),
      owners: Repo.all(from b in Barcode, where: b.code in ^codes, select: {b.code, b.product_id}) |> Map.new()
    }

    {actions, errors, _seen} =
      Enum.reduce(rows, {[], [], %{skus: MapSet.new(), codes: MapSet.new()}}, fn {line, r}, {acts, errs, seen} ->
        row_codes = barcodes(r)
        sku = value(r, "sku")

        cond do
          sku != "" and MapSet.member?(seen.skus, sku) ->
            {acts, [%{row: line, error: "Duplicate sku #{sku} in this file"} | errs], seen}

          dup = Enum.find(row_codes, &MapSet.member?(seen.codes, &1)) ->
            {acts, [%{row: line, error: "Barcode #{dup} appears twice in this file"} | errs], seen}

          true ->
            seen = %{skus: MapSet.put(seen.skus, sku), codes: Enum.reduce(row_codes, seen.codes, &MapSet.put(&2, &1))}

            case plan_row(line, r, ctx) do
              {:ok, action} -> {[action | acts], errs, seen}
              {:error, msg} -> {acts, [%{row: line, error: msg} | errs], seen}
            end
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(actions)}, else: {:error, %{errors: Enum.reverse(errors)}}
  end

  defp plan_row(line, r, ctx) do
    weighed = truthy?(value(r, "weighed"))

    with {:ok, sku} <- required(r, "sku"),
         {:ok, name} <- required(r, "name"),
         {:ok, price} <- money(r, "price", true),
         {:ok, cost} <- money(r, "cost", false),
         {:ok, vat} <- vat(r, ctx.vat),
         {:ok, reorder} <- quantity(r, "reorder_level"),
         {:ok, opening} <- quantity(r, "opening_stock"),
         {:ok, category} <- category(r, ctx.categories) do
      codes = barcodes(r)
      unit = if value(r, "unit") == "", do: (if weighed, do: "kg", else: "each"), else: value(r, "unit")

      attrs =
        %{sku: sku, name: name, price_cents: price, vat_rate_id: vat.id, is_weighed: weighed, unit: unit}
        |> put_if(:cost_cents, cost)
        |> put_if(:reorder_level, reorder)
        |> put_if(:category_id, category && category.id)

      case Map.get(ctx.existing, sku) do
        nil ->
          case Enum.find(codes, &Map.has_key?(ctx.owners, &1)) do
            nil -> {:ok, %{row: line, type: :create, attrs: attrs, barcodes: codes, opening: opening}}
            taken -> {:error, "Barcode #{taken} already belongs to another product"}
          end

        product ->
          case Enum.find(codes, &(Map.has_key?(ctx.owners, &1) and ctx.owners[&1] != product.id)) do
            nil ->
              new_codes = Enum.reject(codes, &Map.has_key?(ctx.owners, &1))
              {:ok, %{row: line, type: :update, product: product, attrs: attrs, barcodes: new_codes}}

            taken ->
              {:error, "Barcode #{taken} already belongs to another product"}
          end
      end
    end
  end

  ## Applying (one transaction)

  defp apply_plan(user, plan) do
    Repo.transaction(fn ->
      Enum.each(plan, fn
        %{type: :create} = a ->
          case Catalog.register_product(user, a.attrs, a.barcodes) do
            {:ok, product} ->
              if a.opening && Decimal.gt?(a.opening, 0) do
                {:ok, _} = Inventory.adjust_stock(product.id, a.opening, :opening, user_id: user.id, note: "CSV import")
              end

            {:error, cs} ->
              Repo.rollback(%{errors: [%{row: a.row, error: "Could not save: #{inspect(cs.errors)}"}]})
          end

        %{type: :update} = a ->
          case Catalog.update_product(user, a.product, a.attrs) do
            {:ok, _} -> Enum.each(a.barcodes, &Repo.insert!(%Barcode{code: &1, product_id: a.product.id}))
            {:error, cs} -> Repo.rollback(%{errors: [%{row: a.row, error: "Could not save: #{inspect(cs.errors)}"}]})
          end
      end)

      Pos.Audit.log(user, "catalog.imported", "catalog", nil, summary(plan, false))
      summary(plan, false)
    end)
  end

  defp summary(plan, dry_run?) do
    %{
      created: Enum.count(plan, &(&1.type == :create)),
      updated: Enum.count(plan, &(&1.type == :update)),
      dry_run: dry_run?
    }
  end

  ## Cell helpers

  defp value(row, key), do: row |> Map.get(key, "") |> String.trim()

  defp barcodes(row), do: row |> value("barcode") |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp required(row, key) do
    case value(row, key) do
      "" -> {:error, "#{key} is empty"}
      v -> {:ok, v}
    end
  end

  defp money(row, key, required?) do
    case value(row, key) do
      "" -> if required?, do: {:error, "#{key} is empty"}, else: {:ok, nil}
      v -> parse_decimal(v, key, &(&1 |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()))
    end
  end

  defp quantity(row, key) do
    case value(row, key) do
      "" -> {:ok, nil}
      v -> parse_decimal(v, key, & &1)
    end
  end

  defp parse_decimal(text, key, convert) do
    case text |> String.replace(",", "") |> Decimal.parse() do
      {d, ""} -> if Decimal.lt?(d, 0), do: {:error, "#{key} cannot be negative"}, else: {:ok, convert.(d)}
      _ -> {:error, "#{key} is not a number: #{text}"}
    end
  end

  defp vat(row, rates) do
    code = row |> value("vat_code") |> String.upcase()

    case Map.get(rates, code) do
      nil -> {:error, "Unknown vat_code #{inspect(code)}"}
      rate -> {:ok, rate}
    end
  end

  # Optional column. The category must already exist, so a typo cannot silently invent one.
  defp category(row, categories) do
    case value(row, "category") do
      "" ->
        {:ok, nil}

      name ->
        case Map.get(categories, String.downcase(name)) do
          nil -> {:error, "Unknown category #{inspect(name)}. Create it first (known: #{categories |> Map.values() |> Enum.map_join(", ", & &1.name)})"}
          category -> {:ok, category}
        end
    end
  end

  defp truthy?(v), do: String.downcase(v) in ["yes", "y", "true", "1"]
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, v), do: Map.put(map, key, v)
end
