defmodule Pos.MpesaTest do
  use Pos.DataCase, async: true
  import Pos.Fixtures

  alias Pos.Payments.{FakeDaraja, Mpesa, MpesaRequest}
  alias Pos.{Repo, Sales}

  setup do
    %{user: user_fixture()}
  end

  defp attrs(opts) do
    %{
      sale_id: Keyword.get(opts, :sale_id, Ecto.UUID.generate()),
      phone: Keyword.get(opts, :phone, "0712345678"),
      amount_cents: Keyword.get(opts, :amount_cents, 10_000)
    }
  end

  defp initiate!(user, opts \\ []) do
    {:ok, request, _} = Mpesa.initiate(user, attrs(opts))
    request
  end

  defp reload(request), do: Repo.get!(MpesaRequest, request.id)

  defp backdate(request, seconds) do
    ago = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Repo.update_all(from(r in MpesaRequest, where: r.id == ^request.id), set: [inserted_at: ago])
    reload(request)
  end

  describe "initiate/2" do
    test "stores a pending request and sends whole shillings to Daraja", %{user: user} do
      request = initiate!(user, amount_cents: 25_000, phone: "0712 345 678")

      assert request.status == :pending
      assert request.phone == "254712345678"
      assert request.checkout_request_id =~ "ws_CO_"
      assert_received {:stk_push, %{amount: 250, phone: "254712345678"}}
    end

    test "normalises Kenyan phone formats" do
      for raw <- ["0712345678", "+254712345678", "254712345678", "712345678", "07 12-345 678"] do
        assert {:ok, "254712345678"} = Mpesa.normalize_phone(raw)
      end

      assert {:ok, "254112345678"} = Mpesa.normalize_phone("0112345678")

      for bad <- ["", "12345", "0612345678", "abc", nil] do
        assert {:error, :invalid_phone} = Mpesa.normalize_phone(bad)
      end
    end

    test "refuses amounts that are not whole shillings", %{user: user} do
      for amount <- [10_050, 50, 0, -100] do
        assert {:error, :amount_must_be_whole_shillings} =
                 Mpesa.initiate(user, attrs(amount_cents: amount))
      end

      refute_received {:stk_push, _}
    end

    test "repeating the call for a sale returns the live request and sends one prompt", %{
      user: user
    } do
      sale_id = Ecto.UUID.generate()
      first = initiate!(user, sale_id: sale_id)
      assert_received {:stk_push, _}

      assert {:ok, second, :existing} = Mpesa.initiate(user, attrs(sale_id: sale_id))
      assert second.id == first.id
      refute_received {:stk_push, _}
    end

    test "a different amount while one is pending is refused", %{user: user} do
      sale_id = Ecto.UUID.generate()
      initiate!(user, sale_id: sale_id)

      assert {:error, :payment_in_progress} =
               Mpesa.initiate(user, attrs(sale_id: sale_id, amount_cents: 20_000))
    end

    test "marks the request failed when Daraja is unreachable, then allows a retry", %{user: user} do
      sale_id = Ecto.UUID.generate()
      FakeDaraja.set_push({:error, :timeout})

      assert {:error, :mpesa_unavailable} = Mpesa.initiate(user, attrs(sale_id: sale_id))
      assert Repo.get_by(MpesaRequest, sale_id: sale_id).status == :failed

      FakeDaraja.set_push(nil)
      assert {:ok, %{status: :pending}, :created} = Mpesa.initiate(user, attrs(sale_id: sale_id))
    end
  end

  describe "callbacks" do
    test "success confirms the request with receipt and payment time", %{user: user} do
      request = initiate!(user)
      assert {:ok, _} = Mpesa.handle_callback(mpesa_callback(request, 0, receipt: "NLJ7RT61SV"))

      confirmed = reload(request)
      assert confirmed.status == :confirmed
      assert confirmed.receipt_number == "NLJ7RT61SV"
      # 10:15:30 East Africa Time is 07:15:30 UTC
      assert confirmed.paid_at == ~U[2026-06-10 07:15:30.000000Z]
      assert confirmed.callback_payload["Body"]
    end

    test "replaying a callback changes nothing", %{user: user} do
      request = initiate!(user)
      Mpesa.handle_callback(mpesa_callback(request, 0, receipt: "FIRST1"))
      Mpesa.handle_callback(mpesa_callback(request, 0, receipt: "SECOND2"))

      assert reload(request).receipt_number == "FIRST1"
    end

    test "a cancelled prompt (1032) fails, an unreachable phone (1037) times out", %{user: user} do
      cancelled = initiate!(user)
      Mpesa.handle_callback(mpesa_callback(cancelled, 1032))
      assert reload(cancelled).status == :failed

      unreachable = initiate!(user)
      Mpesa.handle_callback(mpesa_callback(unreachable, 1037))
      assert reload(unreachable).status == :timed_out
    end

    test "a late success still confirms a request that timed out", %{user: user} do
      request = initiate!(user)
      Mpesa.handle_callback(mpesa_callback(request, 1037))
      Mpesa.handle_callback(mpesa_callback(request, 0))

      assert reload(request).status == :confirmed
    end

    test "a failure never overturns a confirmed payment", %{user: user} do
      request = initiate!(user)
      Mpesa.handle_callback(mpesa_callback(request, 0))
      Mpesa.handle_callback(mpesa_callback(request, 1032))

      assert reload(request).status == :confirmed
    end

    test "a callback with the wrong amount does not confirm", %{user: user} do
      request = initiate!(user, amount_cents: 10_000)
      Mpesa.handle_callback(mpesa_callback(request, 0, amount: 1))

      assert reload(request).status == :failed
    end

    test "unknown checkout ids and garbage are ignored", %{user: user} do
      request = initiate!(user)
      stranger = %{request | checkout_request_id: "ws_CO_nope"}

      assert :ignored = Mpesa.handle_callback(mpesa_callback(stranger))
      assert :ignored = Mpesa.handle_callback(%{"hello" => "world"})
      assert reload(request).status == :pending
    end
  end

  describe "reconciliation" do
    test "a successful query confirms (the query API gives no receipt number)", %{user: user} do
      request = initiate!(user)
      FakeDaraja.set_query({:ok, %{result_code: 0, result_desc: "ok"}})

      assert {:ok, confirmed} = Mpesa.reconcile(request)
      assert confirmed.status == :confirmed
      assert confirmed.receipt_number == nil
    end

    test "a failed query result fails the request", %{user: user} do
      request = initiate!(user)
      FakeDaraja.set_query({:ok, %{result_code: 1032, result_desc: "cancelled"}})

      assert {:ok, %{status: :failed}} = Mpesa.reconcile(request)
    end

    test "an error from Daraja leaves a young request pending", %{user: user} do
      request = initiate!(user)
      assert {:ok, %{status: :pending}} = Mpesa.reconcile(request)
    end

    test "a request with no answer for ten minutes times out", %{user: user} do
      request = user |> initiate!() |> backdate(11 * 60)
      assert {:ok, %{status: :timed_out}} = Mpesa.reconcile(request)
    end

    test "a request that never reached Daraja fails after a minute", %{user: user} do
      request =
        Repo.insert!(%MpesaRequest{
          sale_id: Ecto.UUID.generate(),
          user_id: user.id,
          phone: "254712345678",
          amount_cents: 10_000
        })

      assert {:ok, %{status: :pending}} = Mpesa.reconcile(request)

      request = backdate(request, 120)
      assert {:ok, %{status: :failed}} = Mpesa.reconcile(request)
    end

    test "the sweep skips fresh requests and the worker runs it", %{user: user} do
      request = initiate!(user)
      FakeDaraja.set_query({:ok, %{result_code: 0, result_desc: "ok"}})

      Mpesa.reconcile_pending()
      assert reload(request).status == :pending

      backdate(request, 60)
      assert :ok = Pos.Workers.MpesaReconciler.perform(%Oban.Job{})
      assert reload(request).status == :confirmed
    end

    test "list_unclaimed shows paid requests no sale has used", %{user: user} do
      paid = user |> confirmed_mpesa_request(Ecto.UUID.generate(), 10_000) |> backdate(600)
      initiate!(user)

      assert [%{id: id}] = Mpesa.list_unclaimed()
      assert id == paid.id
    end
  end

  describe "paying a sale with M-Pesa" do
    setup do
      %{product: product_fixture(price_cents: 20_000)}
    end

    defp sale_params(sale_id, product, payments) do
      %{
        "id" => sale_id,
        "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
        "payments" => payments
      }
    end

    defp mpesa(request, amount),
      do: %{"method" => "mpesa", "amount_cents" => amount, "mpesa_request_id" => request.id}

    test "a confirmed request completes the sale and is claimed", %{user: user, product: product} do
      sale_id = Ecto.UUID.generate()
      request = confirmed_mpesa_request(user, sale_id, 20_000)
      params = sale_params(sale_id, product, [mpesa(request, 20_000)])

      assert {:ok, sale} = Sales.create_sale(params, user)
      [payment] = sale.payments
      assert payment.method == :mpesa
      assert payment.reference == request.receipt_number
      assert payment.checkout_request_id == request.checkout_request_id
      assert reload(request).claimed_at

      # The till retrying returns the same sale.
      assert {:ok, again} = Sales.create_sale(params, user)
      assert again.id == sale.id
    end

    test "split tender: M-Pesa for the shillings, cash for the rest", %{
      user: user,
      product: product
    } do
      sale_id = Ecto.UUID.generate()
      request = confirmed_mpesa_request(user, sale_id, 15_000)
      payments = [mpesa(request, 15_000), %{"method" => "cash", "amount_cents" => 5_000}]

      assert {:ok, sale} = Sales.create_sale(sale_params(sale_id, product, payments), user)
      assert length(sale.payments) == 2
    end

    test "refuses a request that is still pending", %{user: user, product: product} do
      sale_id = Ecto.UUID.generate()
      request = initiate!(user, sale_id: sale_id, amount_cents: 20_000)

      assert {:error, :mpesa_payment_not_confirmed} =
               Sales.create_sale(sale_params(sale_id, product, [mpesa(request, 20_000)]), user)

      assert Repo.aggregate(Pos.Sales.Sale, :count) == 0
    end

    test "refuses a request made for a different sale", %{user: user, product: product} do
      request = confirmed_mpesa_request(user, Ecto.UUID.generate(), 20_000)

      assert {:error, :mpesa_wrong_sale} =
               Sales.create_sale(
                 sale_params(Ecto.UUID.generate(), product, [mpesa(request, 20_000)]),
                 user
               )
    end

    test "refuses when the paid amount differs from the payment", %{user: user, product: product} do
      sale_id = Ecto.UUID.generate()
      request = confirmed_mpesa_request(user, sale_id, 10_000)

      assert {:error, :mpesa_amount_mismatch} =
               Sales.create_sale(sale_params(sale_id, product, [mpesa(request, 20_000)]), user)
    end
  end
end
