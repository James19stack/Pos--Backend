defmodule Pos.C2BTest do
  use Pos.DataCase, async: true
  import Pos.Fixtures

  alias Pos.Payments.{C2B, C2BPayment}
  alias Pos.{Repo, Sales}

  setup do
    %{user: user_fixture(), product: product_fixture(price_cents: 20_000)}
  end

  describe "recording confirmations" do
    test "stores the payment with amount, payer and East Africa time" do
      payload = c2b_payload(trans_id: "RKTQDM7W6S", amount: "200.00")
      assert {:ok, _} = C2B.record_confirmation(payload)

      payment = C2B.get_by_code("RKTQDM7W6S")
      assert payment.amount_cents == 20_000
      assert payment.payer_name == "John Doe"
      assert payment.transaction_type == "Buy Goods"
      # 10:15:30 East Africa Time is 07:15:30 UTC
      assert payment.paid_at == ~U[2026-06-10 07:15:30.000000Z]
    end

    test "Safaricom repeating itself does not create a second payment" do
      payload = c2b_payload(trans_id: "RKDUP00001")
      C2B.record_confirmation(payload)
      C2B.record_confirmation(payload)

      assert Repo.aggregate(C2BPayment, :count) == 1
    end

    test "garbage and unreadable amounts are ignored" do
      assert :ignored = C2B.record_confirmation(%{"hello" => "world"})
      assert :ignored = C2B.record_confirmation(c2b_payload(amount: "abc"))
      assert Repo.aggregate(C2BPayment, :count) == 0
    end

    test "codes are found regardless of case and spaces" do
      C2B.record_confirmation(c2b_payload(trans_id: "RKCASE0001"))
      assert C2B.get_by_code("  rkcase0001 ")
      assert C2B.get_by_code("nope") == nil
      assert C2B.get_by_code(nil) == nil
    end

    test "registers URLs containing the secret" do
      assert {:ok, _} = C2B.register_urls()
      assert_received {:register_c2b, %{confirmation_url: url}}
      assert url =~ "/api/callbacks/daraja/"
      assert url =~ "/c2b/confirmation"
    end
  end

  describe "paying a sale with a payment made to the till" do
    defp sale(product, payments, id \\ Ecto.UUID.generate()) do
      %{
        "id" => id,
        "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
        "payments" => payments
      }
    end

    defp till_payment(code, amount),
      do: %{"method" => "mpesa", "amount_cents" => amount, "mpesa_trans_id" => code}

    test "a recorded payment completes the sale and is claimed", %{user: user, product: product} do
      C2B.record_confirmation(c2b_payload(trans_id: "RKPAID0001", amount: "200.00"))
      params = sale(product, [till_payment("RKPAID0001", 20_000)])

      assert {:ok, sale} = Sales.create_sale(params, user)
      [payment] = sale.payments
      assert payment.method == :mpesa
      assert payment.reference == "RKPAID0001"

      claimed = C2B.get_by_code("RKPAID0001")
      assert claimed.claimed_at
      assert claimed.claimed_by_sale_id == sale.id

      # The till retrying returns the same sale.
      assert {:ok, again} = Sales.create_sale(params, user)
      assert again.id == sale.id
    end

    test "split tender: the customer paid part to the till, the rest in cash", %{
      user: user,
      product: product
    } do
      C2B.record_confirmation(c2b_payload(trans_id: "RKPART0001", amount: "150.00"))

      payments = [
        till_payment("RKPART0001", 15_000),
        %{"method" => "cash", "amount_cents" => 5_000}
      ]

      assert {:ok, sale} = Sales.create_sale(sale(product, payments), user)
      assert length(sale.payments) == 2
    end

    test "an unknown code is refused and nothing is saved", %{user: user, product: product} do
      assert {:error, :c2b_payment_not_found} =
               Sales.create_sale(sale(product, [till_payment("FAKE123456", 20_000)]), user)

      assert Repo.aggregate(Pos.Sales.Sale, :count) == 0
    end

    test "the amount must match what the customer actually paid", %{user: user, product: product} do
      C2B.record_confirmation(c2b_payload(trans_id: "RKAMT00001", amount: "100.00"))

      assert {:error, :c2b_amount_mismatch} =
               Sales.create_sale(sale(product, [till_payment("RKAMT00001", 20_000)]), user)
    end

    test "a code cannot pay for a second sale", %{user: user, product: product} do
      C2B.record_confirmation(c2b_payload(trans_id: "RKONCE0001", amount: "200.00"))

      assert {:ok, _} =
               Sales.create_sale(sale(product, [till_payment("RKONCE0001", 20_000)]), user)

      assert {:error, :c2b_payment_already_used} =
               Sales.create_sale(sale(product, [till_payment("RKONCE0001", 20_000)]), user)
    end
  end
end
