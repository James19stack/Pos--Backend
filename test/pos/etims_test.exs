defmodule Pos.EtimsTest do
  # Not async: invoice numbers come from one shared counter
  use Pos.DataCase, async: false
  use Oban.Testing, repo: Pos.Repo
  import Pos.Fixtures

  alias Pos.Etims.Payload
  alias Pos.Etims.Provider.Mock
  alias Pos.{Etims, Repo, Sales}
  alias Pos.Catalog.Product

  setup do
    %{user: user_fixture()}
  end

  defp sell(user, items, payments \\ nil) do
    lines = Enum.map(items, fn {product, qty} -> %{"barcode" => barcode_of(product), "quantity" => qty} end)
    total = items |> Enum.map(fn {p, q} -> p.price_cents * q end) |> Enum.sum()
    payments = payments || [%{"method" => "cash", "amount_cents" => total}]
    {:ok, sale} = Sales.create_sale(%{"id" => Ecto.UUID.generate(), "items" => lines, "payments" => payments}, user)
    sale
  end

  defp invoice(sale), do: Etims.get_invoice_for_sale(sale.id)

  describe "queueing" do
    test "every sale gets the next gap-free invoice number and a queued job", %{user: user} do
      product = product_fixture()
      first = sell(user, [{product, 1}])
      second = sell(user, [{product, 1}])

      assert invoice(first).invoice_no == 1
      assert invoice(second).invoice_no == 2
      assert invoice(first).status == :pending
      assert invoice(first).mode == "mock"
      assert_enqueued(worker: Pos.Workers.EtimsSubmit, args: %{invoice_id: invoice(first).id})
    end

    test "a refused sale takes no invoice number", %{user: user} do
      product = product_fixture()
      bad = %{"id" => Ecto.UUID.generate(), "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}], "payments" => [%{"method" => "cash", "amount_cents" => 5}]}
      assert {:error, _} = Sales.create_sale(bad, user)

      assert invoice(sell(user, [{product, 1}])).invoice_no == 1
    end

    test "a replayed sale does not create a second invoice", %{user: user} do
      product = product_fixture()
      sale = sell(user, [{product, 1}])
      params = %{"id" => sale.id, "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}], "payments" => [%{"method" => "cash", "amount_cents" => product.price_cents}]}

      assert {:ok, _} = Sales.create_sale(params, user)
      assert Repo.aggregate(Pos.Etims.Invoice, :count) == 1
    end
  end

  describe "filing" do
    test "success stores KRA's receipt data and marks the sale", %{user: user} do
      sale = sell(user, [{product_fixture(), 1}])
      assert {:ok, filed} = Etims.submit(invoice(sale).id)

      assert filed.status == :accepted
      assert filed.attempts == 1
      assert String.length(filed.internal_data) == 26
      assert String.length(filed.receipt_signature) == 16
      assert "MOCK" <> _ = filed.receipt_signature
      assert filed.request["invcNo"] == 1

      sale = Repo.get!(Pos.Sales.Sale, sale.id)
      assert sale.etims_status == :accepted
      assert sale.etims_invoice_no == "1"
    end

    test "a KRA failure keeps the invoice pending, records why, and a retry succeeds", %{user: user} do
      sale = sell(user, [{product_fixture(), 1}])
      Mock.set_result({:error, :timeout})

      assert {:error, :timeout} = Etims.submit(invoice(sale).id)
      pending = invoice(sale)
      assert pending.status == :pending
      assert pending.attempts == 1
      assert pending.last_error =~ "timeout"
      assert Repo.get!(Pos.Sales.Sale, sale.id).etims_status == :pending

      Mock.set_result(nil)
      assert {:ok, %{status: :accepted, attempts: 2, last_error: nil}} = Etims.submit(pending.id)
    end

    test "an accepted invoice is never sent twice", %{user: user} do
      sale = sell(user, [{product_fixture(), 1}])
      {:ok, _} = Etims.submit(invoice(sale).id)
      assert_received {:etims_submit, _}

      assert {:ok, %{status: :accepted}} = Etims.submit(invoice(sale).id)
      refute_received {:etims_submit, _}
    end

    test "the worker files the invoice and reports failures so Oban retries", %{user: user} do
      sale = sell(user, [{product_fixture(), 1}])
      job = %Oban.Job{args: %{"invoice_id" => invoice(sale).id}}

      Mock.set_result({:error, :timeout})
      assert {:error, :timeout} = Pos.Workers.EtimsSubmit.perform(job)
      Mock.set_result(nil)
      assert :ok = Pos.Workers.EtimsSubmit.perform(job)
      assert Pos.Workers.EtimsSubmit.backoff(%Oban.Job{attempt: 1}) == 30
      assert Pos.Workers.EtimsSubmit.backoff(%Oban.Job{attempt: 50}) == 3600
    end

    test "unfiled invoices show up on the watch-list once they are old enough", %{user: user} do
      sale = sell(user, [{product_fixture(), 1}])
      assert Etims.list_pending() == []

      ago = DateTime.add(DateTime.utc_now(), -600, :second)
      Repo.update_all(from(i in Pos.Etims.Invoice, where: i.sale_id == ^sale.id), set: [inserted_at: ago])
      assert [%{sale_id: id}] = Etims.list_pending()
      assert id == sale.id
    end
  end

  describe "item registration" do
    test "a product is registered with KRA once, with a stable item code", %{user: user} do
      product = product_fixture()
      one = sell(user, [{product, 1}])
      two = sell(user, [{product, 1}])

      {:ok, _} = Etims.submit(invoice(one).id)
      assert_received {:etims_save_item, item}
      assert item["itemCd"] =~ ~r/^KE2NTU\d{7}$/
      assert item["taxTyCd"] == "B"
      assert item["dftPrc"] == 100.0

      {:ok, _} = Etims.submit(invoice(two).id)
      refute_received {:etims_save_item, _}

      registered = Repo.get!(Product, product.id)
      assert registered.etims_item_cd == item["itemCd"]
      assert registered.etims_registered_at
    end

    test "a failed registration blocks the invoice but is retried", %{user: user} do
      sale = sell(user, [{product_fixture(), 1}])
      Mock.set_result({:error, :timeout})
      assert {:error, :timeout} = Etims.submit(invoice(sale).id)
      refute_received {:etims_submit, _}

      Mock.set_result(nil)
      assert {:ok, _} = Etims.submit(invoice(sale).id)
    end
  end

  describe "payload" do
    setup %{user: user} do
      standard = product_fixture(price_cents: 11_600)
      exempt = product_fixture(price_cents: 5_000, vat_rate: vat_rate_fixture(%{code: "A", name: "Exempt", rate_bp: 0}))
      sale = sell(user, [{standard, 2}, {exempt, 1}])
      %{sale: Etims.load_sale(sale.id)}
    end

    test "totals and tax bands in shillings", %{sale: sale} do
      p = Payload.build(sale, 7, Etims.config())

      assert p["invcNo"] == 7
      assert p["trdInvcNo"] == sale.id
      assert p["pmtTyCd"] == "01"
      assert p["totItemCnt"] == 2
      assert p["totAmt"] == 282.0
      assert p["totTaxAmt"] == 32.0
      assert p["taxRtB"] == 16.0
      assert p["taxAmtB"] == 32.0
      assert p["taxAmtA"] == 0.0
      assert p["salesDt"] =~ ~r/^\d{8}$/
      assert p["cfmDt"] =~ ~r/^\d{14}$/
    end

    test "gross taxable basis follows the spec's sample; net is one setting away", %{sale: sale} do
      gross = Payload.build(sale, 1, Etims.config())
      assert gross["taxblAmtB"] == 232.0
      assert gross["taxblAmtA"] == 50.0

      net = Payload.build(sale, 1, %{Etims.config() | taxable_basis: :net})
      assert net["taxblAmtB"] == 200.0
      assert net["totTaxblAmt"] == 250.0
    end

    test "item lines", %{sale: sale} do
      [first, second] = Payload.build(sale, 1, Etims.config())["itemList"]

      assert %{"itemSeq" => 1, "qty" => 2.0, "prc" => 116.0, "totAmt" => 232.0, "taxTyCd" => "B", "taxAmt" => 32.0} = first
      assert %{"itemSeq" => 2, "taxTyCd" => "A", "totAmt" => 50.0} = second
    end

    test "split payments report the method that paid most", %{user: user} do
      product = product_fixture(price_cents: 10_000)
      payments = [%{"method" => "cash", "amount_cents" => 3_000}, %{"method" => "card", "amount_cents" => 7_000, "reference" => "A1"}]
      sale = user |> sell([{product, 1}], payments) |> then(&Etims.load_sale(&1.id))

      assert Payload.build(sale, 1, Etims.config())["pmtTyCd"] == "05"
    end
  end
end
