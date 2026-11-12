defmodule Pos.SalesTest do
  use Pos.DataCase, async: true
  import Pos.Fixtures

  alias Pos.{Inventory, Repo, Sales}
  alias Pos.Sales.Sale

  setup do
    %{cashier: user_fixture()}
  end

  defp sale_params(items, payments, extra \\ %{}) do
    Map.merge(%{"id" => Ecto.UUID.generate(), "items" => items, "payments" => payments}, extra)
  end

  defp item(product, qty), do: %{"barcode" => barcode_of(product), "quantity" => qty}
  defp cash(amount, tendered \\ nil), do: %{"method" => "cash", "amount_cents" => amount, "tendered_cents" => tendered}

  describe "totals and VAT" do
    test "computes totals, VAT and change on the server", %{cashier: cashier} do
      # KES 116.00 inclusive of 16% VAT => VAT is 16.00
      product = product_fixture(price_cents: 11_600)

      assert {:ok, sale} =
               Sales.create_sale(sale_params([item(product, 2)], [cash(23_200, 25_000)]), cashier)

      assert sale.total_cents == 23_200
      assert sale.vat_cents == 3_200
      assert sale.status == :completed
      assert sale.cashier_id == cashier.id
      assert Sales.change_due_cents(sale) == 1_800

      [line] = sale.items
      assert line.unit_price_cents == 11_600
      assert line.vat_rate_bp == 1600
      assert line.line_total_cents == 23_200
      assert line.product_name == product.name
    end

    test "handles mixed VAT rates", %{cashier: cashier} do
      standard = product_fixture(price_cents: 11_600)
      exempt_rate = vat_rate_fixture(%{code: "A", name: "Exempt", rate_bp: 0})
      exempt = product_fixture(price_cents: 5_000, vat_rate: exempt_rate)

      assert {:ok, sale} =
               Sales.create_sale(
                 sale_params([item(standard, 1), item(exempt, 1)], [cash(16_600)]),
                 cashier
               )

      assert sale.total_cents == 16_600
      assert sale.vat_cents == 1_600
    end

    test "prices weighed items by decimal quantity", %{cashier: cashier} do
      # 1.5 kg at KES 200.00/kg = 300.00; VAT = 30000 * 1600 / 11600 = 4137.93 => 4138
      product = product_fixture(price_cents: 20_000, is_weighed: true)

      assert {:ok, sale} =
               Sales.create_sale(sale_params([item(product, "1.5")], [cash(30_000)]), cashier)

      assert sale.total_cents == 30_000
      assert sale.vat_cents == 4_138
    end

    test "ignores prices sent by the client", %{cashier: cashier} do
      product = product_fixture(price_cents: 10_000)

      items = [%{"barcode" => barcode_of(product), "quantity" => 1, "unit_price_cents" => 1}]

      assert {:ok, sale} = Sales.create_sale(sale_params(items, [cash(10_000)]), cashier)
      assert sale.total_cents == 10_000
    end
  end

  describe "stock" do
    test "deducts stock and writes a ledger entry", %{cashier: cashier} do
      product = product_fixture(stock: 100)

      assert {:ok, sale} =
               Sales.create_sale(sale_params([item(product, 2)], [cash(20_000)]), cashier)

      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 98)

      movement =
        Repo.one!(
          from m in Pos.Inventory.StockMovement,
            where: m.reference_id == ^sale.id
        )

      assert movement.reason == :sale
      assert Decimal.eq?(movement.quantity, -2)
      assert movement.user_id == cashier.id
    end

    test "flags the sale for review instead of blocking when stock goes negative", %{cashier: cashier} do
      product = product_fixture(stock: 1)

      assert {:ok, sale} =
               Sales.create_sale(sale_params([item(product, 3)], [cash(30_000)]), cashier)

      assert sale.needs_review
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), -2)
    end

    test "does not flag a sale when stock is sufficient", %{cashier: cashier} do
      product = product_fixture(stock: 10)

      assert {:ok, sale} =
               Sales.create_sale(sale_params([item(product, 3)], [cash(30_000)]), cashier)

      refute sale.needs_review
    end
  end

  describe "idempotency" do
    test "the same sale id returns the original and does not deduct stock twice", %{cashier: cashier} do
      product = product_fixture(stock: 100)
      params = sale_params([item(product, 2)], [cash(20_000)])

      assert {:ok, first} = Sales.create_sale(params, cashier)
      assert {:ok, second} = Sales.create_sale(params, cashier)

      assert first.id == second.id
      assert Repo.aggregate(Sale, :count) == 1
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 98)
    end

    test "rejects an invalid sale id", %{cashier: cashier} do
      product = product_fixture()
      params = sale_params([item(product, 1)], [cash(10_000)], %{"id" => "not-a-uuid"})

      assert {:error, :invalid_id} = Sales.create_sale(params, cashier)
    end
  end

  describe "validation (nothing is saved on failure)" do
    test "rejects payments that do not cover the total", %{cashier: cashier} do
      product = product_fixture(stock: 100)

      assert {:error, {:payment_mismatch, %{expected_cents: 10_000, received_cents: 5_000}}} =
               Sales.create_sale(sale_params([item(product, 1)], [cash(5_000)]), cashier)

      assert Repo.aggregate(Sale, :count) == 0
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 100)
    end

    test "supports split tender across cash and card", %{cashier: cashier} do
      product = product_fixture(price_cents: 10_000)

      payments = [cash(4_000), %{"method" => "card", "amount_cents" => 6_000, "reference" => "APPR123"}]

      assert {:ok, sale} = Sales.create_sale(sale_params([item(product, 1)], payments), cashier)
      assert length(sale.payments) == 2
    end

    test "rejects cash tendered below the amount due", %{cashier: cashier} do
      product = product_fixture()

      assert {:error, :insufficient_tender} =
               Sales.create_sale(sale_params([item(product, 1)], [cash(10_000, 5_000)]), cashier)
    end

    test "requires an approval reference for card payments", %{cashier: cashier} do
      product = product_fixture()
      payments = [%{"method" => "card", "amount_cents" => 10_000}]

      assert {:error, :card_reference_required} =
               Sales.create_sale(sale_params([item(product, 1)], payments), cashier)
    end

    test "M-Pesa is not handled by this flow yet", %{cashier: cashier} do
      product = product_fixture()
      payments = [%{"method" => "mpesa", "amount_cents" => 10_000}]

      assert {:error, {:unsupported_payment_method, :mpesa}} =
               Sales.create_sale(sale_params([item(product, 1)], payments), cashier)
    end

    test "rejects unknown barcodes", %{cashier: cashier} do
      params = sale_params([%{"barcode" => "000", "quantity" => 1}], [cash(100)])
      assert {:error, {:unknown_barcode, "000"}} = Sales.create_sale(params, cashier)
    end

    test "rejects empty carts and missing payments", %{cashier: cashier} do
      product = product_fixture()
      assert {:error, :no_items} = Sales.create_sale(sale_params([], [cash(100)]), cashier)
      assert {:error, :no_payments} = Sales.create_sale(sale_params([item(product, 1)], []), cashier)
    end

    test "rejects zero, negative and fractional quantities", %{cashier: cashier} do
      product = product_fixture()

      for {qty, error} <- [{0, :invalid_quantity}, {-1, :invalid_quantity}, {"abc", :invalid_quantity}, {"1.5", :fractional_quantity}] do
        assert {:error, ^error} =
                 Sales.create_sale(sale_params([item(product, qty)], [cash(10_000)]), cashier)
      end
    end

    test "saves nothing when the cashier does not exist", %{cashier: cashier} do
      product = product_fixture(stock: 100)
      ghost = %{cashier | id: Ecto.UUID.generate()}

      assert {:error, %Ecto.Changeset{}} =
               Sales.create_sale(sale_params([item(product, 1)], [cash(10_000)]), ghost)

      assert Repo.aggregate(Sale, :count) == 0
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 100)
    end
  end
end
