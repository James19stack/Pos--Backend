defmodule Pos.Reversals do
  @moduledoc """
  Voids and returns, both needing a supervisor's approval.

  A cashier asks, and a supervisor or manager types their own email and password to
  approve it (`approver_email` / `approver_password`). Supervisors and above need no one else.

  - VOID: cancels a cash sale in a shift that is still open, and puts the stock back. Sales
    paid by card or M-Pesa, and sales from closed shifts, go through a RETURN instead.
  - RETURN: refunds some or all items of any completed sale, any time. The money comes out of
    the processing cashier's current drawer, so it is recorded on THEIR open shift.
  - Each unit can be returned once. Refunds are proportional, and the last unit takes the exact
    remainder, so rounding can never refund more or less than was paid.
  - Reports stay honest: voided sales leave the sales totals, returns are shown separately.
  - Refusing both while eTIMS holds an accepted invoice: that needs a KRA credit note, which
    is not built.
  """
  import Ecto.Query, warn: false

  alias Pos.{Accounts, Audit, Etims, Inventory, Repo, Shifts}
  alias Pos.Accounts.User
  alias Pos.Reversals.{Return, ReturnItem}
  alias Pos.Sales.Sale
  alias Pos.Shifts.Shift

  ## Voiding

  def void_sale(%User{} = actor, sale_id, attrs) do
    with {:ok, approver} <- approver(actor, attrs),
         {:ok, reason} <- reason(attrs[:reason]) do
      Repo.transaction(fn -> do_void(actor, approver, sale_id, reason) end)
    end
  end

  defp do_void(actor, approver, sale_id, reason) do
    sale = lock_sale(sale_id) || Repo.rollback(:not_found)
    shift = if sale.shift_id, do: Repo.get(Shift, sale.shift_id)
    ok!(voidable(sale, shift, actor))

    Enum.each(sale.items, &restock!(&1.product_id, &1.quantity, :void, sale.id, actor))

    voided =
      sale
      |> Ecto.Changeset.change(
        status: :voided,
        voided_at: DateTime.utc_now(),
        voided_by_id: actor.id,
        void_reason: reason,
        void_approved_by_id: approver.id
      )
      |> Repo.update!()

    Audit.log(actor, "sale.voided", "sale", sale.id, %{reason: reason, approved_by: approver.id, total_cents: sale.total_cents})
    voided
  end

  defp voidable(sale, shift, actor) do
    cond do
      sale.status != :completed -> {:error, :not_voidable}
      is_nil(shift) or shift.status != :open -> {:error, :shift_closed_use_return}
      actor.role == :cashier and shift.user_id != actor.id -> {:error, :not_your_sale}
      Enum.any?(sale.payments, &(&1.method != :cash)) -> {:error, :void_needs_cash_only}
      returned?(sale.id) -> {:error, :already_returned}
      Etims.accepted?(sale.id) -> {:error, :etims_credit_note_not_supported}
      true -> :ok
    end
  end

  ## Returning

  def return_items(%User{} = actor, sale_id, %{id: id, items: items} = attrs) when is_list(items) and items != [] do
    case get_return(id) do
      %Return{} = existing ->
        {:ok, existing}

      nil ->
        with {:ok, approver} <- approver(actor, attrs),
             {:ok, reason} <- reason(attrs[:reason]),
             {:ok, method} <- method(attrs[:refund_method]),
             {:ok, shift} <- Shifts.fetch_open(actor) do
          Repo.transaction(fn -> do_return(actor, approver, shift, sale_id, id, reason, method, items) end)
        end
    end
  end

  def return_items(_actor, _sale_id, _attrs), do: {:error, :no_items}

  defp do_return(actor, approver, shift, sale_id, id, reason, method, items) do
    sale = lock_sale(sale_id) || Repo.rollback(:not_found)
    ok!(returnable_sale(sale))

    so_far = returned_totals(sale.items)
    lines = items |> merge_requested() |> Enum.map(&plan_line(&1, sale.items, so_far))

    return =
      Repo.insert!(%Return{
        id: id,
        sale_id: sale.id,
        shift_id: shift.id,
        user_id: actor.id,
        approved_by_id: approver.id,
        reason: reason,
        refund_method: method,
        refund_cents: lines |> Enum.map(& &1.cents) |> Enum.sum(),
        refund_vat_cents: lines |> Enum.map(& &1.vat) |> Enum.sum()
      })

    Enum.each(lines, fn l ->
      Repo.insert!(%ReturnItem{
        return_id: return.id,
        sale_item_id: l.item.id,
        product_id: l.item.product_id,
        quantity: l.qty,
        refund_cents: l.cents,
        refund_vat_cents: l.vat
      })

      restock!(l.item.product_id, l.qty, :return, sale.id, actor)
    end)

    Audit.log(actor, "sale.returned", "sale", sale.id, %{return_id: id, reason: reason, refund_cents: return.refund_cents, method: method, approved_by: approver.id})
    Repo.preload(return, :items)
  end

  defp returnable_sale(sale) do
    cond do
      sale.status != :completed -> {:error, :not_returnable}
      Etims.accepted?(sale.id) -> {:error, :etims_credit_note_not_supported}
      true -> :ok
    end
  end

  # The same barcode asked for twice in one request counts as one line.
  defp merge_requested(items) do
    items
    |> Enum.group_by(&Map.get(&1, :barcode), &to_decimal(Map.get(&1, :quantity)))
    |> Enum.map(fn {barcode, qtys} ->
      if Enum.any?(qtys, &(&1 == :error or Decimal.compare(&1, 0) != :gt)), do: Repo.rollback(:invalid_quantity)
      {barcode, Enum.reduce(qtys, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp plan_line({barcode, qty}, sale_items, so_far) do
    candidates = Enum.filter(sale_items, &(&1.barcode == barcode))
    if candidates == [], do: Repo.rollback(:item_not_on_sale)

    item = Enum.find(candidates, &(Decimal.compare(remaining_of(&1, so_far), qty) != :lt)) || Repo.rollback(:return_exceeds_sold)
    {cents, vat} = refund(item, Map.get(so_far, item.id, {Decimal.new(0), 0, 0}), qty)
    %{item: item, qty: qty, cents: cents, vat: vat}
  end

  # The last unit takes the exact remainder; earlier ones a proportional share.
  defp refund(item, {returned_qty, returned_cents, returned_vat}, qty) do
    if Decimal.eq?(qty, Decimal.sub(item.quantity, returned_qty)) do
      {item.line_total_cents - returned_cents, item.line_vat_cents - returned_vat}
    else
      {share(item.line_total_cents, qty, item.quantity), share(item.line_vat_cents, qty, item.quantity)}
    end
  end

  defp share(amount, qty, total_qty) do
    amount |> Decimal.new() |> Decimal.mult(qty) |> Decimal.div(total_qty) |> Decimal.round(0, :half_up) |> Decimal.to_integer()
  end

  ## Reading

  def get_return(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Return |> Repo.get(uuid) |> Repo.preload(:items)
      :error -> nil
    end
  end

  def list_returns(sale_id), do: Repo.all(from r in Return, where: r.sale_id == ^sale_id, order_by: r.inserted_at, preload: :items)

  @doc "How much of each line can still be returned: %{sale_item_id => Decimal}."
  def remaining(%Sale{items: items}) do
    so_far = returned_totals(items)
    Map.new(items, &{&1.id, remaining_of(&1, so_far)})
  end

  defp remaining_of(item, so_far) do
    {returned, _, _} = Map.get(so_far, item.id, {Decimal.new(0), 0, 0})
    Decimal.sub(item.quantity, returned)
  end

  defp returned_totals(items) do
    ids = Enum.map(items, & &1.id)

    from(ri in ReturnItem,
      where: ri.sale_item_id in ^ids,
      group_by: ri.sale_item_id,
      select: {ri.sale_item_id, sum(ri.quantity), sum(ri.refund_cents), sum(ri.refund_vat_cents)}
    )
    |> Repo.all()
    |> Map.new(fn {id, qty, cents, vat} -> {id, {qty, to_int(cents), to_int(vat)}} end)
  end

  defp returned?(sale_id), do: Repo.exists?(from r in Return, where: r.sale_id == ^sale_id)

  ## Helpers

  defp lock_sale(sale_id) do
    from(s in Sale, where: s.id == ^sale_id, lock: "FOR UPDATE") |> Repo.one() |> Repo.preload([:items, :payments])
  end

  defp restock!(product_id, qty, reason, sale_id, actor) do
    movement = %{product_id: product_id, quantity: qty, reason: reason, reference_type: "sale", reference_id: sale_id, user_id: actor.id}

    case Inventory.apply_movement(Repo, movement) do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Cashiers need a supervisor's credentials; supervisors and above approve for themselves.
  defp approver(%User{} = actor, attrs) do
    if User.at_least?(actor, :supervisor),
      do: {:ok, actor},
      else: Accounts.authorize_override(attrs[:approver_email], attrs[:approver_password])
  end

  defp reason(r) when is_binary(r), do: if(String.trim(r) == "", do: {:error, :reason_required}, else: {:ok, String.trim(r)})
  defp reason(_), do: {:error, :reason_required}

  defp method(nil), do: {:ok, "cash"}
  defp method(m) when m in ["cash", "other"], do: {:ok, m}
  defp method(_), do: {:error, :invalid_refund_method}

  defp ok!(:ok), do: :ok
  defp ok!({:error, reason}), do: Repo.rollback(reason)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(n) when is_binary(n) do
    case Decimal.parse(n) do
      {d, ""} -> d
      _ -> :error
    end
  end

  defp to_decimal(_), do: :error

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(i), do: i
end
