defmodule Pos.Shifts do
  @moduledoc """
  A shift is one cashier on one till, from opening float to cash-up.

  - Nothing can be sold without an open shift.
  - Cash-up is blind: the cashier enters what they counted, and the server compares it
    with float + cash taken. The cashier never sees the expected figure first.
  - A difference over the threshold needs a manager's approval, and nobody can approve
    their own shift.
  - The Z report is frozen when the shift closes.
  """
  import Ecto.Query, warn: false

  alias Pos.Accounts.User
  alias Pos.Payments.Payment
  alias Pos.Repo
  alias Pos.Reversals.Return
  alias Pos.Sales.{Sale, SaleItem}
  alias Pos.Shifts.Shift

  # A cash difference larger than this (KES 500) needs a manager.
  @approval_threshold_cents 50_000

  def approval_threshold_cents, do: @approval_threshold_cents

  ## Reading

  def get_shift(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Shift, uuid)
      :error -> nil
    end
  end

  def get_open_shift(%User{id: user_id}) do
    open = :open
    Repo.one(from s in Shift, where: s.user_id == ^user_id and s.status == ^open)
  end

  def fetch_open(%User{} = user) do
    case get_open_shift(user) do
      nil -> {:error, :no_open_shift}
      shift -> {:ok, shift}
    end
  end

  def list_pending do
    pending = :pending_approval
    Repo.all(from s in Shift, where: s.status == ^pending, order_by: [asc: s.closed_at])
  end

  @doc """
  Used inside the sale transaction. FOR SHARE means a sale in progress and a cash-up
  can never interleave: closing waits for in-flight sales, and later sales are refused.
  """
  def lock_open(repo, shift_id) do
    open = :open

    case repo.one(from s in Shift, where: s.id == ^shift_id and s.status == ^open, lock: "FOR SHARE") do
      nil -> {:error, :no_open_shift}
      shift -> {:ok, shift}
    end
  end

  ## Opening

  def open_shift(%User{} = user, %{opening_float_cents: float} = attrs) do
    changeset =
      Shift.open_changeset(%Shift{}, %{
        user_id: user.id,
        device_id: Map.get(attrs, :device_id) || "till-1",
        opening_float_cents: float,
        opened_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, shift} ->
        {:ok, shift}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        cond do
          Keyword.has_key?(errors, :user_id) -> {:error, :shift_already_open}
          Keyword.has_key?(errors, :device_id) -> {:error, :till_in_use}
          true -> {:error, cs}
        end
    end
  end

  ## Closing (cash-up)

  @doc "Blind cash-up. `counted` is what the cashier counted in the drawer, in cents."
  def close_shift(%User{id: user_id}, counted) when is_integer(counted) and counted >= 0 do
    open = :open

    Repo.transaction(fn ->
      # Waits for any sale that is mid-transaction, and blocks new ones.
      case Repo.one(from s in Shift, where: s.user_id == ^user_id and s.status == ^open, lock: "FOR UPDATE") do
        nil -> Repo.rollback(:no_open_shift)
        shift -> do_close(shift, counted)
      end
    end)
  end

  def close_shift(_user, _counted), do: {:error, :invalid_count}

  defp do_close(shift, counted) do
    now = DateTime.utc_now()
    report = report(%{shift | closed_at: now})
    expected = report.cash.expected_cash_cents
    difference = counted - expected
    status = if abs(difference) > @approval_threshold_cents, do: :pending_approval, else: :closed

    z =
      report
      |> put_in([:shift, :status], status)
      |> put_in([:cash, :counted_cash_cents], counted)
      |> put_in([:cash, :difference_cents], difference)

    shift
    |> Ecto.Changeset.change(%{
      status: status,
      closed_at: now,
      counted_cash_cents: counted,
      expected_cash_cents: expected,
      difference_cents: difference,
      z_report: z
    })
    |> Repo.update!()
  end

  @doc "A manager signs off a cash difference. Never your own shift."
  def approve_shift(%User{} = approver, shift_id, note) do
    pending = :pending_approval

    Repo.transaction(fn ->
      case Repo.one(from s in Shift, where: s.id == ^shift_id and s.status == ^pending, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %{user_id: owner} when owner == approver.id ->
          Repo.rollback(:cannot_approve_own_shift)

        shift ->
          shift
          |> Ecto.Changeset.change(
            status: :closed,
            approved_by_id: approver.id,
            approved_at: DateTime.utc_now(),
            close_note: note
          )
          |> Repo.update!()
      end
    end)
  end

  ## Reports

  @doc """
  X report while the shift is open, Z report once it is closed. Money is integer cents.
  Expected cash = opening float + cash actually applied to sales (change given is excluded).
  """
  def report(%Shift{} = shift) do
    completed = :completed
    confirmed = :confirmed
    sales = from(s in Sale, where: s.shift_id == ^shift.id and s.status == ^completed)

    {count, total, vat, review} =
      Repo.one(
        select(sales, [s], {count(s.id), sum(s.total_cents), sum(s.vat_cents), fragment("count(*) filter (where ?)", s.needs_review)})
      )

    by_method =
      from(p in Payment,
        join: s in Sale,
        on: p.sale_id == s.id,
        where: s.shift_id == ^shift.id and s.status == ^completed and p.status == ^confirmed,
        group_by: p.method,
        order_by: p.method,
        select: {p.method, count(p.id), sum(p.amount_cents)}
      )
      |> Repo.all()
      |> Enum.map(fn {method, n, amount} -> %{method: Atom.to_string(method), count: n, amount_cents: int(amount)} end)

    vat_by_code =
      from(i in SaleItem,
        join: s in Sale,
        on: i.sale_id == s.id,
        where: s.shift_id == ^shift.id and s.status == ^completed,
        group_by: [i.vat_code, i.vat_rate_bp],
        order_by: [i.vat_code, i.vat_rate_bp],
        select: {i.vat_code, i.vat_rate_bp, sum(i.line_total_cents), sum(i.line_vat_cents)}
      )
      |> Repo.all()
      |> Enum.map(fn {code, rate, gross, vat_amount} ->
        %{vat_code: code, vat_rate_bp: rate, gross_cents: int(gross), vat_cents: int(vat_amount)}
      end)

    cash_sales = by_method |> Enum.find(%{amount_cents: 0}, &(&1.method == "cash")) |> Map.fetch!(:amount_cents)

    voided = :voided

    {void_count, void_total} =
      Repo.one(from s in Sale, where: s.shift_id == ^shift.id and s.status == ^voided, select: {count(s.id), sum(s.total_cents)})

    {return_count, return_cents, return_vat, cash_refunds} =
      Repo.one(
        from r in Return,
          where: r.shift_id == ^shift.id,
          select: {count(r.id), sum(r.refund_cents), sum(r.refund_vat_cents), fragment("coalesce(sum(?) filter (where ? = 'cash'), 0)", r.refund_cents, r.refund_method)}
      )

    cash_refunds = int(cash_refunds)

    %{
      shift: %{
        id: shift.id,
        user_id: shift.user_id,
        device_id: shift.device_id,
        status: shift.status,
        opened_at: shift.opened_at,
        closed_at: shift.closed_at
      },
      sales_count: count,
      total_sales_cents: int(total),
      vat_cents: int(vat),
      needs_review_count: review,
      voids: %{count: void_count, total_cents: int(void_total)},
      returns: %{count: return_count, refund_cents: int(return_cents), vat_cents: int(return_vat), cash_refund_cents: cash_refunds},
      by_payment_method: by_method,
      vat_by_code: vat_by_code,
      cash: %{
        opening_float_cents: shift.opening_float_cents,
        cash_sales_cents: cash_sales,
        cash_refunds_cents: cash_refunds,
        expected_cash_cents: shift.opening_float_cents + cash_sales - cash_refunds
      }
    }
  end

  defp int(nil), do: 0
  defp int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp int(i) when is_integer(i), do: i
end
