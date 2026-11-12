defmodule Pos.ReversalsTest do
  # Not async: a few tests switch eTIMS on, which is a global setting
  use Pos.DataCase, async: false
  import Pos.Fixtures

  alias Pos.{Audit, Etims, Inventory, Repo, Reversals, Sales, Shifts}
  alias Pos.Sales.Sale

  @password "password123"

  setup do
    on_exit(fn -> Application.delete_env(:pos, :etims_enabled) end)

    %{
      cashier: user_fixture(),
      supervisor: user_fixture(%{role: :supervisor}),
      product: product_fixture(price_cents: 10_000, stock: 100)
    }
  end

  defp sell(user, product, qty \\ 1, payments \\ nil) do
    total = product.price_cents * qty
    payments = payments || [%{"method" => "cash", "amount_cents" => total}]
    params = %{"id" => Ecto.UUID.generate(), "items" => [%{"barcode" => barcode_of(product), "quantity" => qty}], "payments" => payments}
    {:ok, sale} = Sales.create_sale(params, user)
    sale
  end

  defp approval(sup), do: %{approver_email: sup.email, approver_password: @password}
  defp stock(product), do: Inventory.stock_on_hand(product.id)

  defp ret(user, sale, product, qty, extra \\ %{}) do
    attrs = Map.merge(%{id: Ecto.UUID.generate(), reason: "Damaged", items: [%{barcode: barcode_of(product), quantity: qty}]}, extra)
    Reversals.return_items(user, sale.id, attrs)
  end

  describe "void" do
    test "a cashier voids their own cash sale with a supervisor's credentials", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 2)
      assert Decimal.eq?(stock(product), 98)

      assert {:ok, voided} = Reversals.void_sale(cashier, sale.id, Map.merge(%{reason: "Changed mind"}, approval(sup)))
      assert voided.status == :voided
      assert voided.void_reason == "Changed mind"
      assert voided.void_approved_by_id == sup.id
      assert Decimal.eq?(stock(product), 100)
      assert Enum.any?(Audit.for_entity("sale", sale.id), &(&1.action == "sale.voided"))

      report = Shifts.report(Shifts.get_open_shift(cashier))
      assert report.sales_count == 0
      assert report.voids == %{count: 1, total_cents: 20_000}
      assert report.cash.expected_cash_cents == 0
    end

    test "wrong credentials, a cashier as approver, or no reason all stop it", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product)
      other_cashier = user_fixture()

      assert {:error, :invalid_approval} = Reversals.void_sale(cashier, sale.id, %{reason: "x", approver_email: sup.email, approver_password: "wrong-pass"})
      assert {:error, :invalid_approval} = Reversals.void_sale(cashier, sale.id, %{reason: "x", approver_email: other_cashier.email, approver_password: @password})
      assert {:error, :invalid_approval} = Reversals.void_sale(cashier, sale.id, %{reason: "x"})
      assert {:error, :reason_required} = Reversals.void_sale(cashier, sale.id, Map.merge(%{reason: "  "}, approval(sup)))
      assert Repo.get!(Sale, sale.id).status == :completed
    end

    test "supervisors need no one else, and can void any open-shift sale", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product)
      assert {:ok, %{status: :voided}} = Reversals.void_sale(sup, sale.id, %{reason: "Wrong item"})
    end

    test "a cashier cannot void someone else's sale", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product)
      other = user_fixture()
      assert {:error, :not_your_sale} = Reversals.void_sale(other, sale.id, Map.merge(%{reason: "x"}, approval(sup)))
    end

    test "only once, only cash, only while the shift is open, and not after a return", %{cashier: cashier, supervisor: sup, product: product} do
      ask = fn sale -> Reversals.void_sale(sup, sale.id, %{reason: "x"}) end

      sale = sell(cashier, product)
      assert {:ok, _} = ask.(sale)
      assert {:error, :not_voidable} = ask.(sale)

      card = sell(cashier, product, 1, [%{"method" => "card", "amount_cents" => 10_000, "reference" => "A1"}])
      assert {:error, :void_needs_cash_only} = ask.(card)

      returned = sell(cashier, product)
      {:ok, _} = ret(sup, returned, product, 1)
      assert {:error, :already_returned} = ask.(returned)

      old = sell(cashier, product)
      {:ok, _} = Shifts.close_shift(cashier, 0 + 20_000)
      assert {:error, :shift_closed_use_return} = ask.(old)

      assert {:error, :not_found} = Reversals.void_sale(sup, Ecto.UUID.generate(), %{reason: "x"})
    end

    test "is refused once eTIMS has an accepted invoice for the sale", %{cashier: cashier, supervisor: sup, product: product} do
      Application.put_env(:pos, :etims_enabled, true)
      sale = sell(cashier, product)
      {:ok, _} = Etims.submit(Etims.get_invoice_for_sale(sale.id).id)

      assert {:error, :etims_credit_note_not_supported} = Reversals.void_sale(sup, sale.id, %{reason: "x"})
    end
  end

  describe "returns" do
    test "a partial return refunds proportionally, restocks, and comes out of the drawer", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 3)
      assert {:ok, ret} = ret(cashier, sale, product, 1, approval(sup))

      assert ret.refund_cents == 10_000
      assert ret.refund_vat_cents == 1_379
      assert ret.approved_by_id == sup.id
      assert Decimal.eq?(stock(product), 98)

      report = Shifts.report(Shifts.get_open_shift(cashier))
      assert report.returns == %{count: 1, refund_cents: 10_000, vat_cents: 1_379, cash_refund_cents: 10_000}
      assert report.sales_count == 1
      assert report.cash.expected_cash_cents == 30_000 - 10_000
    end

    test "returning everything refunds exactly what was paid, however it rounds", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 3)
      {:ok, a} = ret(sup, sale, product, 1)
      {:ok, b} = ret(sup, sale, product, 1)
      {:ok, c} = ret(sup, sale, product, 1)

      assert a.refund_cents + b.refund_cents + c.refund_cents == 30_000
      assert a.refund_vat_cents + b.refund_vat_cents + c.refund_vat_cents == 4_138
      assert c.refund_vat_cents == 1_380
    end

    test "cannot return more than was sold, or something that was not on the sale", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 3)

      assert {:error, :return_exceeds_sold} = ret(sup, sale, product, 4)
      {:ok, _} = ret(sup, sale, product, 3)
      assert {:error, :return_exceeds_sold} = ret(sup, sale, product, 1)
      assert {:error, :item_not_on_sale} = ret(sup, sale, product_fixture(), 1)
      assert {:error, :invalid_quantity} = ret(sup, sale, product, 0)
      assert Decimal.eq?(stock(product), 100)
    end

    test "a retried return is recorded once", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 2)
      attrs = %{id: Ecto.UUID.generate(), reason: "Damaged", items: [%{barcode: barcode_of(product), quantity: 1}]}

      assert {:ok, first} = Reversals.return_items(sup, sale.id, attrs)
      assert {:ok, second} = Reversals.return_items(sup, sale.id, attrs)
      assert first.id == second.id
      assert Decimal.eq?(stock(product), 99)
    end

    test "needs approval, a reason, a valid method and an open shift", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product)

      assert {:error, :invalid_approval} = ret(cashier, sale, product, 1)
      assert {:error, :reason_required} = ret(sup, sale, product, 1, %{reason: ""})
      assert {:error, :invalid_refund_method} = ret(sup, sale, product, 1, %{refund_method: "gold"})

      no_shift = user_fixture(%{role: :supervisor, open_shift: false})
      assert {:error, :no_open_shift} = ret(no_shift, sale, product, 1)
    end

    test "a voided sale cannot be returned", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product)
      {:ok, _} = Reversals.void_sale(sup, sale.id, %{reason: "x"})
      assert {:error, :not_returnable} = ret(sup, sale, product, 1)
    end

    test "the refund is recorded on the shift that pays it, not the sale's shift", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 2)
      first_shift = Shifts.get_open_shift(cashier)
      {:ok, _} = Shifts.close_shift(cashier, 20_000)
      {:ok, second_shift} = Shifts.open_shift(cashier, %{opening_float_cents: 5_000, device_id: "till-later"})

      assert {:ok, _} = ret(cashier, sale, product, 1, approval(sup))

      assert Shifts.report(first_shift).returns.count == 0
      assert Shifts.report(second_shift).returns.cash_refund_cents == 10_000
      assert Shifts.report(second_shift).cash.expected_cash_cents == 5_000 - 10_000
    end

    test "money refunded outside the system does not touch the drawer", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product)
      {:ok, ret} = ret(cashier, sale, product, 1, Map.merge(approval(sup), %{refund_method: "other"}))

      assert ret.refund_method == "other"
      report = Shifts.report(Shifts.get_open_shift(cashier))
      assert report.returns.refund_cents == 10_000
      assert report.returns.cash_refund_cents == 0
      assert report.cash.expected_cash_cents == 10_000
    end

    test "a receipt number finds the sale, with what is still returnable", %{cashier: cashier, supervisor: sup, product: product} do
      sale = sell(cashier, product, 3)
      {:ok, _} = ret(sup, sale, product, 1)

      found = Sales.get_sale_by_receipt("  " <> String.downcase(sale.receipt_no) <> " ")
      assert found.id == sale.id
      [item] = found.items
      assert Decimal.eq?(Reversals.remaining(found)[item.id], 2)
      assert Sales.get_sale_by_receipt("R-NOPE") == nil
    end
  end
end
