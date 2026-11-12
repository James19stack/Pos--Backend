defmodule Pos.ShiftsTest do
  use Pos.DataCase, async: true
  import Pos.Fixtures

  alias Pos.{Repo, Sales, Shifts}
  alias Pos.Sales.Sale

  defp cashier_with_float(float) do
    user = user_fixture(%{open_shift: false})

    {:ok, shift} =
      Shifts.open_shift(user, %{
        opening_float_cents: float,
        device_id: "till-#{System.unique_integer([:positive])}"
      })

    {user, shift}
  end

  defp sell(user, product, payments, id \\ Ecto.UUID.generate()) do
    params = %{
      "id" => id,
      "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
      "payments" => payments
    }

    Sales.create_sale(params, user)
  end

  defp cash(amount, tendered \\ nil),
    do: %{"method" => "cash", "amount_cents" => amount, "tendered_cents" => tendered}

  describe "opening" do
    test "opens a shift with a float" do
      user = user_fixture(%{open_shift: false})

      assert {:ok, shift} =
               Shifts.open_shift(user, %{opening_float_cents: 500_000, device_id: "till-a"})

      assert shift.status == :open
      assert shift.opening_float_cents == 500_000
    end

    test "a cashier cannot have two open shifts" do
      user = user_fixture()

      assert {:error, :shift_already_open} =
               Shifts.open_shift(user, %{opening_float_cents: 0, device_id: "till-other"})
    end

    test "one till cannot have two open shifts" do
      first = user_fixture(%{open_shift: false})
      second = user_fixture(%{open_shift: false})

      assert {:ok, _} =
               Shifts.open_shift(first, %{opening_float_cents: 0, device_id: "till-shared"})

      assert {:error, :till_in_use} =
               Shifts.open_shift(second, %{opening_float_cents: 0, device_id: "till-shared"})
    end

    test "rejects a negative float" do
      user = user_fixture(%{open_shift: false})

      assert {:error, %Ecto.Changeset{}} =
               Shifts.open_shift(user, %{opening_float_cents: -1, device_id: "till-n"})
    end
  end

  describe "selling" do
    test "a sale needs an open shift, and nothing is saved without one" do
      user = user_fixture(%{open_shift: false})
      product = product_fixture()

      assert {:error, :no_open_shift} = sell(user, product, [cash(10_000)])
      assert Repo.aggregate(Sale, :count) == 0
    end

    test "the sale is attached to the open shift" do
      {user, shift} = cashier_with_float(0)
      assert {:ok, sale} = sell(user, product_fixture(), [cash(10_000)])
      assert sale.shift_id == shift.id
    end

    test "no more sales once the shift is closed" do
      {user, _} = cashier_with_float(0)
      {:ok, _} = Shifts.close_shift(user, 0)

      assert {:error, :no_open_shift} = sell(user, product_fixture(), [cash(10_000)])
    end

    test "a sale recorded before closing can still be replayed afterwards" do
      {user, _} = cashier_with_float(0)
      product = product_fixture()
      id = Ecto.UUID.generate()

      assert {:ok, sale} = sell(user, product, [cash(10_000)], id)
      {:ok, _} = Shifts.close_shift(user, 10_000)

      assert {:ok, again} = sell(user, product, [cash(10_000)], id)
      assert again.id == sale.id
    end
  end

  describe "report" do
    test "totals by payment method and VAT code, with expected cash" do
      {user, shift} = cashier_with_float(10_000)
      standard = product_fixture(price_cents: 11_600)

      exempt =
        product_fixture(
          price_cents: 5_000,
          vat_rate: vat_rate_fixture(%{code: "A", name: "Exempt", rate_bp: 0})
        )

      # cash with change: only the amount applied (11_600) counts as cash in the drawer
      {:ok, _} = sell(user, standard, [cash(11_600, 20_000)])

      {:ok, _} =
        sell(user, exempt, [
          %{"method" => "card", "amount_cents" => 5_000, "reference" => "APPR1"}
        ])

      report = Shifts.report(shift)

      assert report.sales_count == 2
      assert report.total_sales_cents == 16_600
      assert report.vat_cents == 1_600

      assert %{count: 1, amount_cents: 11_600} =
               Enum.find(report.by_payment_method, &(&1.method == "cash"))

      assert %{count: 1, amount_cents: 5_000} =
               Enum.find(report.by_payment_method, &(&1.method == "card"))

      assert %{gross_cents: 11_600, vat_cents: 1_600} =
               Enum.find(report.vat_by_code, &(&1.vat_code == "B"))

      assert %{gross_cents: 5_000, vat_cents: 0} =
               Enum.find(report.vat_by_code, &(&1.vat_code == "A"))

      assert report.cash.opening_float_cents == 10_000
      assert report.cash.cash_sales_cents == 11_600
      assert report.cash.expected_cash_cents == 21_600
    end

    test "an empty shift reports zeros" do
      {_user, shift} = cashier_with_float(5_000)
      report = Shifts.report(shift)

      assert report.sales_count == 0
      assert report.by_payment_method == []
      assert report.cash.expected_cash_cents == 5_000
    end
  end

  describe "cash-up" do
    test "an exact count closes the shift and freezes the Z report" do
      {user, shift} = cashier_with_float(10_000)
      {:ok, _} = sell(user, product_fixture(price_cents: 10_000), [cash(10_000)])

      assert {:ok, closed} = Shifts.close_shift(user, 20_000)
      assert closed.status == :closed
      assert closed.expected_cash_cents == 20_000
      assert closed.difference_cents == 0
      assert closed.closed_at

      # A new shift and more sales must not change the old Z report
      {:ok, _} = Shifts.open_shift(user, %{opening_float_cents: 0, device_id: "till-next"})
      {:ok, _} = sell(user, product_fixture(price_cents: 10_000), [cash(10_000)])

      frozen = Shifts.get_shift(shift.id).z_report
      assert frozen["sales_count"] == 1
      assert frozen["cash"]["counted_cash_cents"] == 20_000
      assert frozen["cash"]["difference_cents"] == 0
    end

    test "a small difference (within KES 500) still closes" do
      {user, _} = cashier_with_float(50_000)
      # expected 50_000, counted 30_000: KES 200 short
      assert {:ok, closed} = Shifts.close_shift(user, 30_000)
      assert closed.status == :closed
      assert closed.difference_cents == -20_000
    end

    test "a difference over KES 500 waits for a manager" do
      {user, _} = cashier_with_float(10_000)
      # expected 10_000, counted 70_000: KES 600 over
      assert {:ok, closed} = Shifts.close_shift(user, 70_000)
      assert closed.status == :pending_approval
      assert closed.difference_cents == 60_000
      assert [%{id: id}] = Shifts.list_pending()
      assert id == closed.id
    end

    test "closing without an open shift fails" do
      user = user_fixture(%{open_shift: false})
      assert {:error, :no_open_shift} = Shifts.close_shift(user, 0)
      assert {:error, :invalid_count} = Shifts.close_shift(user, -5)
    end
  end

  describe "approval" do
    test "a manager approves a pending shift, once" do
      {cashier, _} = cashier_with_float(0)
      {:ok, pending} = Shifts.close_shift(cashier, 100_000)
      assert pending.status == :pending_approval

      manager = user_fixture(%{role: :manager})
      assert {:ok, approved} = Shifts.approve_shift(manager, pending.id, "Checked the safe")
      assert approved.status == :closed
      assert approved.approved_by_id == manager.id
      assert approved.close_note == "Checked the safe"

      assert {:error, :not_found} = Shifts.approve_shift(manager, pending.id, nil)
    end

    test "nobody can approve their own shift" do
      manager = user_fixture(%{role: :manager})
      {:ok, pending} = Shifts.close_shift(manager, 100_000)

      assert {:error, :cannot_approve_own_shift} = Shifts.approve_shift(manager, pending.id, nil)
      assert Shifts.get_shift(pending.id).status == :pending_approval
    end
  end
end
