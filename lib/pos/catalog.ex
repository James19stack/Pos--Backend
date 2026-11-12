defmodule Pos.Catalog do
  import Ecto.Query, warn: false

  alias Pos.Accounts.User
  alias Pos.Audit
  alias Pos.Catalog.{Barcode, Category, Product, VatRate}
  alias Pos.Repo

  ## VAT rates

  def create_vat_rate(attrs) do
    %VatRate{} |> VatRate.changeset(attrs) |> Repo.insert()
  end

  def get_vat_rate_by_code(code), do: Repo.get_by(VatRate, code: code)

  ## Products

  @doc "Creates a product and its barcodes in one transaction."
  def create_product(attrs, barcodes \\ []) do
    Repo.transaction(fn ->
      with {:ok, product} <- %Product{} |> Product.changeset(attrs) |> Repo.insert(),
           :ok <- insert_barcodes(product, barcodes) do
        Repo.preload(product, [:vat_rate, :barcodes, :category])
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_barcodes(product, codes) do
    Enum.reduce_while(codes, :ok, fn code, :ok ->
      case %Barcode{}
           |> Barcode.changeset(%{code: code, product_id: product.id})
           |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc "Finds an active product by barcode, with its VAT rate loaded. Returns nil if none."
  def get_product_by_barcode(code) when is_binary(code) do
    code = String.trim(code)

    from(p in Product,
      join: b in Barcode,
      on: b.product_id == p.id,
      where: b.code == ^code and p.active == true,
      preload: [:vat_rate, :barcodes]
    )
    |> Repo.one()
  end

  def get_product_by_barcode(_), do: nil

  @doc "Everything a till needs to cache locally (later stored in IndexedDB)."
  def list_catalog do
    from(p in Product,
      where: p.active == true,
      order_by: p.name,
      preload: [:vat_rate, :barcodes]
    )
    |> Repo.all()
  end

  ## Back office

  @audited [:name, :price_cents, :cost_cents, :vat_rate_id, :is_weighed, :active, :reorder_level, :etims_item_cls_cd, :pkg_unit_cd, :qty_unit_cd, :category_id]

  def get_product(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Product |> Repo.get(uuid) |> Repo.preload([:vat_rate, :barcodes, :stock_level, :category])
      :error -> nil
    end
  end

  @doc "Search by name, sku or exact barcode. Options: :q, :limit (max 200), :offset."
  def list_products(opts \\ []) do
    q = opts |> Keyword.get(:q) |> to_string() |> String.trim()
    limit = min(Keyword.get(opts, :limit) || 50, 200)

    base =
      from p in Product,
        order_by: p.name,
        limit: ^limit,
        offset: ^(Keyword.get(opts, :offset) || 0),
        preload: [:vat_rate, :barcodes, :stock_level, :category]

    if q == "" do
      Repo.all(base)
    else
      like = "%" <> String.replace(q, ["\\", "%", "_"], fn m -> "\\" <> m end) <> "%"

      Repo.all(
        from p in base,
          left_join: b in Barcode,
          on: b.product_id == p.id,
          where: ilike(p.name, ^like) or ilike(p.sku, ^like) or b.code == ^q,
          distinct: true
      )
    end
  end

  @doc "Creates a product and records who did it."
  def register_product(%User{} = user, attrs, barcodes \\ []) do
    with {:ok, product} <- create_product(attrs, barcodes) do
      Audit.log(user, "product.created", "product", product.id, %{sku: product.sku, price_cents: product.price_cents})
      {:ok, product}
    end
  end

  @doc "Updates a product; any change to price, cost, VAT, name or status is audited with old and new values."
  def update_product(%User{} = user, %Product{} = product, attrs) do
    Repo.transaction(fn ->
      case product |> Product.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          changes =
            for field <- @audited, Map.get(product, field) != Map.get(updated, field), into: %{} do
              {field, %{from: audit_value(Map.get(product, field)), to: audit_value(Map.get(updated, field))}}
            end

          if map_size(changes) > 0, do: Audit.log(user, "product.updated", "product", product.id, changes)
          Repo.preload(updated, [:vat_rate, :barcodes, :stock_level, :category], force: true)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp audit_value(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp audit_value(v), do: v

  ## Categories (default KRA codes for their products)

  def list_categories, do: Repo.all(from c in Category, order_by: fragment("lower(?)", c.name))

  def get_category(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Category, uuid)
      :error -> nil
    end
  end

  def create_category(%User{} = user, attrs) do
    with {:ok, category} <- %Category{} |> Category.changeset(attrs) |> Repo.insert() do
      Audit.log(user, "category.created", "category", category.id, %{name: category.name})
      {:ok, category}
    end
  end

  def update_category(%User{} = user, %Category{} = category, attrs) do
    Repo.transaction(fn ->
      case category |> Category.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          changes =
            for f <- [:name, :etims_item_cls_cd, :pkg_unit_cd, :qty_unit_cd], Map.get(category, f) != Map.get(updated, f), into: %{} do
              {f, %{from: Map.get(category, f), to: Map.get(updated, f)}}
            end

          if map_size(changes) > 0, do: Audit.log(user, "category.updated", "category", category.id, changes)
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end
end
