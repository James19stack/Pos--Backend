defmodule Pos.Fixtures do
  alias Pos.{Accounts, Catalog, Inventory}

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {open_shift?, attrs} = attrs |> Map.new() |> Map.pop(:open_shift, true)

    {:ok, user} =
      %{name: "Test User", email: "user#{n}@example.com", password: "password123", role: :cashier}
      |> Map.merge(attrs)
      |> Accounts.register_user()

    # Selling needs an open shift, so test users get one (own till, zero float)
    if open_shift?,
      do:
        {:ok, _} = Pos.Shifts.open_shift(user, %{opening_float_cents: 0, device_id: "till-#{n}"})

    user
  end

  def vat_rate_fixture(attrs \\ %{}) do
    attrs = Map.merge(%{code: "B", name: "Standard", rate_bp: 1600}, Map.new(attrs))

    case Catalog.get_vat_rate_by_code(attrs.code) do
      nil ->
        {:ok, rate} = Catalog.create_vat_rate(attrs)
        rate

      rate ->
        rate
    end
  end

  @doc """
  Options: :price_cents (default 10_000), :stock (default 100), :vat_rate,
  :is_weighed, :barcode, :name
  """
  def product_fixture(opts \\ []) do
    vat_rate = Keyword.get_lazy(opts, :vat_rate, fn -> vat_rate_fixture() end)
    n = System.unique_integer([:positive])
    barcode = Keyword.get(opts, :barcode, "616" <> String.pad_leading("#{n}", 10, "0"))

    {:ok, product} =
      Catalog.create_product(
        %{
          sku: "SKU#{n}",
          name: Keyword.get(opts, :name, "Test product #{n}"),
          price_cents: Keyword.get(opts, :price_cents, 10_000),
          vat_rate_id: vat_rate.id,
          is_weighed: Keyword.get(opts, :is_weighed, false)
        },
        [barcode]
      )

    stock = Keyword.get(opts, :stock, 100)
    if stock != 0, do: {:ok, _} = Inventory.adjust_stock(product.id, stock, :opening)

    product
  end

  def barcode_of(product), do: hd(product.barcodes).code

  @doc "The body Safaricom POSTs to the callback URL."
  def mpesa_callback(request, code \\ 0, opts \\ []) do
    cb = %{
      "MerchantRequestID" => "29115-34620561-1",
      "CheckoutRequestID" => request.checkout_request_id,
      "ResultCode" => code,
      "ResultDesc" => "result #{code}"
    }

    cb =
      if code == 0 do
        receipt =
          Keyword.get(
            opts,
            :receipt,
            "RCP" <> Integer.to_string(System.unique_integer([:positive]))
          )

        amount = Keyword.get(opts, :amount, div(request.amount_cents, 100))

        Map.put(cb, "CallbackMetadata", %{
          "Item" => [
            %{"Name" => "Amount", "Value" => amount},
            %{"Name" => "MpesaReceiptNumber", "Value" => receipt},
            %{"Name" => "TransactionDate", "Value" => 20_260_610_101_530},
            %{"Name" => "PhoneNumber", "Value" => 254_712_345_678}
          ]
        })
      else
        cb
      end

    %{"Body" => %{"stkCallback" => cb}}
  end

  @doc "A request that has been paid: prompt sent, then a success callback."
  def confirmed_mpesa_request(user, sale_id, amount_cents) do
    {:ok, request, _} =
      Pos.Payments.Mpesa.initiate(user, %{
        sale_id: sale_id,
        phone: "0712345678",
        amount_cents: amount_cents
      })

    {:ok, _} = Pos.Payments.Mpesa.handle_callback(mpesa_callback(request))
    Pos.Repo.get!(Pos.Payments.MpesaRequest, request.id)
  end

  @doc "The body Safaricom POSTs to the C2B Confirmation URL."
  def c2b_payload(opts \\ []) do
    %{
      "TransactionType" => Keyword.get(opts, :type, "Buy Goods"),
      "TransID" =>
        Keyword.get(
          opts,
          :trans_id,
          "RK" <> Integer.to_string(System.unique_integer([:positive]))
        ),
      "TransTime" => "20260610101530",
      "TransAmount" => Keyword.get(opts, :amount, "200.00"),
      "BusinessShortCode" => "600966",
      "BillRefNumber" => "",
      "InvoiceNumber" => "",
      "OrgAccountBalance" => "25.00",
      "ThirdPartyTransID" => "",
      "MSISDN" => "2547*****126",
      "FirstName" => "John",
      "MiddleName" => "",
      "LastName" => "Doe"
    }
  end
end
