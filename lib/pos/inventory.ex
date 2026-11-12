defmodule Pos.Inventory do
  @moduledoc """
  Stock is an append-only ledger (stock_movements). stock_levels is a cached
  running total, updated atomically in the same transaction as each movement.
  """
  import Ecto.Query, warn: false

  alias Pos.Accounts.User
  alias Pos.{Audit, Catalog}
  alias Pos.Catalog.Product
  alias Pos.Inventory.{GoodsReceipt, GoodsReceiptItem, StockLevel, StockMovement}
  alias Pos.Repo

  def stock_on_hand(product_id) do
    from(l in StockLevel, where: l.product_id == ^product_id, select: l.quantity)
    |> Repo.one()
    |> Kernel.||(Decimal.new(0))
  end

  @doc """
  Records a signed stock movement (positive = in, negative = out) and updates
  the cached level. Runs in its own transaction.
  """
  def adjust_stock(product_id, quantity, reason, opts \\ []) do
    attrs = %{
      product_id: product_id,
      quantity: Decimal.new(quantity),
      reason: reason,
      reference_type: opts[:reference_type],
      reference_id: opts[:reference_id],
      user_id: opts[:user_id],
      note: opts[:note]
    }

    Repo.transaction(fn ->
      case apply_movement(Repo, attrs) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Inserts the movement and atomically bumps the cached level. Must be called
  inside a transaction (the Sales Multi does this). Returns the new on-hand
  quantity so callers can detect negative stock.
  """
  def apply_movement(repo, attrs) do
    with {:ok, movement} <- %StockMovement{} |> StockMovement.changeset(attrs) |> repo.insert() do
      now = DateTime.utc_now()
      product_id = movement.product_id
      qty = movement.quantity

      # Make sure a level row exists, then increment it in the database so
      # concurrent sales never overwrite each other.
      repo.insert_all(
        StockLevel,
        [%{product_id: product_id, quantity: Decimal.new(0), updated_at: now}],
        on_conflict: :nothing,
        conflict_target: :product_id
      )

      {1, [new_qty]} =
        repo.update_all(
          from(l in StockLevel,
            where: l.product_id == ^product_id,
            select: l.quantity,
            update: [inc: [quantity: ^qty], set: [updated_at: ^now]]
          ),
          []
        )

      {:ok, %{movement: movement, quantity: new_qty}}
    end
  end

  ## Back office

  @adjustment_reasons [:adjustment, :wastage, :expiry]

  @doc """
  Manual stock change with a mandatory note. Wastage and expiry always take stock OUT,
  whatever sign was sent; `:adjustment` is signed (+ found, - lost). Audited.
  """
  def record_adjustment(%User{} = user, product_id, quantity, reason, note) when reason in @adjustment_reasons do
    with {:ok, qty} <- to_decimal(quantity),
         :ok <- check_note(note) do
      qty = if reason in [:wastage, :expiry], do: qty |> Decimal.abs() |> Decimal.negate(), else: qty

      Repo.transaction(fn ->
        case apply_movement(Repo, %{product_id: product_id, quantity: qty, reason: reason, user_id: user.id, note: note}) do
          {:ok, result} ->
            Audit.log(user, "stock." <> Atom.to_string(reason), "product", product_id, %{
              quantity: Decimal.to_string(qty, :normal),
              note: note
            })

            result

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  def record_adjustment(_user, _product_id, _quantity, _reason, _note), do: {:error, :invalid_reason}

  defp check_note(note) when is_binary(note), do: if(String.trim(note) == "", do: {:error, :note_required}, else: :ok)
  defp check_note(_), do: {:error, :note_required}

  defp to_decimal(%Decimal{} = d), do: {:ok, d}
  defp to_decimal(n) when is_integer(n), do: {:ok, Decimal.new(n)}
  defp to_decimal(n) when is_float(n), do: {:ok, Decimal.from_float(n)}

  defp to_decimal(n) when is_binary(n) do
    case Decimal.parse(n) do
      {d, ""} -> {:ok, d}
      _ -> {:error, :invalid_quantity}
    end
  end

  defp to_decimal(_), do: {:error, :invalid_quantity}

  @doc "Active products at or below their reorder level, including ones never stocked."
  def low_stock do
    from(p in Product,
      left_join: l in StockLevel,
      on: l.product_id == p.id,
      where: p.active == true and fragment("coalesce(?, 0)", l.quantity) <= p.reorder_level,
      order_by: [asc: fragment("coalesce(?, 0)", l.quantity), asc: p.name],
      select: {p, fragment("coalesce(?, 0)", l.quantity)},
      preload: [:vat_rate, :barcodes]
    )
    |> Repo.all()
  end

  def movements(product_id, limit \\ 100) do
    Repo.all(from m in StockMovement, where: m.product_id == ^product_id, order_by: [desc: m.id], limit: ^limit)
  end

  ## Receiving goods

  def get_receipt(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> GoodsReceipt |> Repo.get(uuid) |> Repo.preload(:items)
      :error -> nil
    end
  end

  @doc """
  Posts a delivery: stock in, and each product's cost updated (audited). Idempotent on `id`,
  so a double-tap or retry returns the original receipt. Items name a product by `barcode`
  or `sku`, with `quantity` and optionally `unit_cost_cents`.
  """
  def receive_goods(%User{} = user, %{id: id, items: items} = attrs) when is_list(items) and items != [] do
    case get_receipt(id) do
      %GoodsReceipt{} = existing ->
        {:ok, existing}

      nil ->
        with {:ok, lines} <- resolve_items(items) do
          Repo.transaction(fn -> post_receipt(user, id, attrs, lines) end)
        end
    end
  end

  def receive_goods(_user, _attrs), do: {:error, :no_items}

  defp resolve_items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      ref = Map.get(item, :barcode) || Map.get(item, :sku)

      with %Product{} = product <- find_product(item),
           {:ok, qty} <- to_decimal(item[:quantity]),
           true <- Decimal.gt?(qty, 0) do
        {:cont, {:ok, [%{product: product, quantity: qty, unit_cost_cents: item[:unit_cost_cents]} | acc]}}
      else
        nil -> {:halt, {:error, {:unknown_barcode, ref}}}
        _ -> {:halt, {:error, :invalid_quantity}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  defp find_product(%{barcode: code}) when is_binary(code), do: Catalog.get_product_by_barcode(code)
  defp find_product(%{sku: sku}) when is_binary(sku), do: Repo.get_by(Product, sku: sku, active: true)
  defp find_product(_), do: nil

  defp post_receipt(user, id, attrs, lines) do
    receipt =
      Repo.insert!(%GoodsReceipt{
        id: id,
        supplier_name: attrs[:supplier_name],
        reference: attrs[:reference],
        note: attrs[:note],
        received_by_id: user.id,
        received_at: DateTime.utc_now()
      })

    Enum.each(lines, fn line ->
      cost = line.unit_cost_cents || line.product.cost_cents

      Repo.insert!(%GoodsReceiptItem{
        goods_receipt_id: receipt.id,
        product_id: line.product.id,
        quantity: line.quantity,
        unit_cost_cents: cost
      })

      movement = %{
        product_id: line.product.id,
        quantity: line.quantity,
        reason: :grn,
        reference_type: "goods_receipt",
        reference_id: receipt.id,
        user_id: user.id
      }

      case apply_movement(Repo, movement) do
        {:ok, _} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end

      if cost != line.product.cost_cents do
        {:ok, _} = Catalog.update_product(user, line.product, %{cost_cents: cost})
      end
    end)

    Audit.log(user, "goods_receipt.posted", "goods_receipt", receipt.id, %{items: length(lines), reference: attrs[:reference]})
    Repo.preload(receipt, :items)
  end
end
