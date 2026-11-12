defmodule Pos.Payments.Mpesa do
  @moduledoc """
  M-Pesa STK Push, handled asynchronously and kept apart from sales.

  Flow:
    1. The till calls `initiate/2` for a sale id it generated. A `pending` request is
       stored and Daraja prompts the customer's phone.
    2. Safaricom calls our callback (`handle_callback/1`), or the reconciler asks
       Daraja (`reconcile/1`) if the callback never arrives. Request becomes
       `confirmed`, `failed` or `timed_out`.
    3. The till submits the normal sale with an `mpesa` payment naming the request.
       `Sales` checks the request is confirmed, matches the sale and amount, and
       claims it, all inside the sale's transaction.

  A request that is confirmed but never claimed means "customer paid, no sale was
  recorded" (till crashed, cashier abandoned). `list_unclaimed/1` surfaces these.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Pos.Accounts.User
  alias Pos.Payments.{Daraja, MpesaRequest}
  alias Pos.Repo

  # Don't query Daraja for requests younger than this: the callback usually wins.
  @min_query_age 30
  # No answer from callback or query for this long: give up as timed out.
  @hard_timeout 600
  # A request with no checkout id after this long never reached Daraja.
  @init_grace 60

  ## Reading

  def get_request(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(MpesaRequest, uuid)
      :error -> nil
    end
  end

  @doc "Confirmed payments no sale has claimed, older than `min_age` seconds."
  def list_unclaimed(min_age \\ 300) do
    cutoff = DateTime.add(DateTime.utc_now(), -min_age, :second)
    confirmed = :confirmed

    from(r in MpesaRequest,
      where: r.status == ^confirmed and is_nil(r.claimed_at) and r.inserted_at < ^cutoff,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  ## Starting a payment

  @doc """
  Returns {:ok, request, :created | :existing}. Repeating the call for the same
  sale with the same phone and amount returns the live request and sends nothing.
  """
  def initiate(%User{} = user, %{sale_id: sale_id, phone: raw_phone, amount_cents: amount}) do
    with {:ok, phone} <- normalize_phone(raw_phone),
         :ok <- validate_amount(amount) do
      case active_request(sale_id) do
        %MpesaRequest{amount_cents: ^amount, phone: ^phone} = existing ->
          {:ok, existing, :existing}

        %MpesaRequest{} ->
          {:error, :payment_in_progress}

        nil ->
          create_and_push(user, sale_id, phone, amount)
      end
    end
  end

  def normalize_phone(raw) when is_binary(raw) do
    digits = String.replace(raw, ~r/\D/, "")

    local =
      case digits do
        "254" <> rest -> rest
        "0" <> rest -> rest
        rest -> rest
      end

    if byte_size(local) == 9 and String.starts_with?(local, ["7", "1"]),
      do: {:ok, "254" <> local},
      else: {:error, :invalid_phone}
  end

  def normalize_phone(_), do: {:error, :invalid_phone}

  # STK Push cannot charge cents.
  defp validate_amount(a) when is_integer(a) and a >= 100 and rem(a, 100) == 0, do: :ok
  defp validate_amount(_), do: {:error, :amount_must_be_whole_shillings}

  defp active_request(sale_id) do
    live = [:pending, :confirmed]

    from(r in MpesaRequest,
      where: r.sale_id == ^sale_id and r.status in ^live,
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp create_and_push(user, sale_id, phone, amount) do
    changeset =
      MpesaRequest.create_changeset(%MpesaRequest{}, %{
        sale_id: sale_id,
        user_id: user.id,
        phone: phone,
        amount_cents: amount
      })

    case Repo.insert(changeset) do
      {:ok, request} ->
        push(request)

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        # Lost a race with an identical tap: the other request is the live one.
        if Keyword.has_key?(errors, :sale_id),
          do: {:error, :payment_in_progress},
          else: {:error, cs}
    end
  end

  defp push(request) do
    params = %{
      amount: div(request.amount_cents, 100),
      phone: request.phone,
      # Daraja limits: reference 12 chars, description 13.
      account_reference: "POS" <> String.slice(request.id, 0, 8),
      description: "Supermarket",
      callback_url: callback_url()
    }

    case Daraja.impl().stk_push(params) do
      {:ok, %{checkout_request_id: checkout_id, merchant_request_id: merchant_id}} ->
        {:ok, updated} =
          request
          |> Ecto.Changeset.change(
            checkout_request_id: checkout_id,
            merchant_request_id: merchant_id
          )
          |> Repo.update()

        {:ok, updated, :created}

      {:error, reason} ->
        Logger.warning("Daraja STK push failed for request #{request.id}: #{inspect(reason)}")

        request
        |> Ecto.Changeset.change(status: :failed, result_desc: "Could not reach M-Pesa")
        |> Repo.update()

        {:error, :mpesa_unavailable}
    end
  end

  defp callback_url do
    cfg = Application.fetch_env!(:pos, :daraja)

    String.trim_trailing(cfg[:callback_base_url] || "", "/") <>
      "/api/callbacks/daraja/" <> (cfg[:callback_secret] || "")
  end

  ## Results: callback and reconciliation

  @doc "Handles the body Safaricom POSTs to our callback URL."
  def handle_callback(%{
        "Body" => %{
          "stkCallback" => %{"CheckoutRequestID" => checkout_id, "ResultCode" => code} = cb
        }
      }) do
    case Repo.get_by(MpesaRequest, checkout_request_id: checkout_id) do
      nil ->
        :ignored

      request ->
        apply_result(request.id, to_int(code), cb["ResultDesc"], parse_metadata(cb), %{
          "Body" => %{"stkCallback" => cb}
        })
    end
  end

  def handle_callback(_), do: :ignored

  @doc "Asks Daraja about a pending request (used when the callback is missing)."
  def reconcile(%MpesaRequest{status: :pending, checkout_request_id: nil} = request) do
    if age(request) > @init_grace,
      do: apply_result(request.id, -1, "STK request was never sent", %{}, nil),
      else: {:ok, request}
  end

  def reconcile(%MpesaRequest{status: :pending} = request) do
    case Daraja.impl().query(request.checkout_request_id) do
      {:ok, %{result_code: code, result_desc: desc}} ->
        apply_result(request.id, code, desc, %{}, nil)

      {:error, _still_unknown} ->
        if age(request) > @hard_timeout,
          do:
            apply_result(request.id, 1037, "No answer from Daraja, timed out locally", %{}, nil),
          else: {:ok, request}
    end
  end

  def reconcile(%MpesaRequest{} = request), do: {:ok, request}

  @doc "Sweeps pending requests. Run every minute by Oban."
  def reconcile_pending do
    cutoff = DateTime.add(DateTime.utc_now(), -@min_query_age, :second)
    pending = :pending

    from(r in MpesaRequest, where: r.status == ^pending and r.inserted_at < ^cutoff)
    |> Repo.all()
    |> Enum.map(&reconcile/1)
  end

  # Row-locked so a callback and the reconciler can never apply conflicting results.
  defp apply_result(id, code, desc, meta, payload) do
    Repo.transaction(fn ->
      request = Repo.one!(from r in MpesaRequest, where: r.id == ^id, lock: "FOR UPDATE")

      case decide(request, code, meta) do
        :ignore ->
          request

        {:update, changes} ->
          changes = Map.merge(changes, %{result_code: code, result_desc: desc})
          changes = if payload, do: Map.put(changes, :callback_payload, payload), else: changes
          request |> Ecto.Changeset.change(changes) |> Repo.update!()
      end
    end)
  end

  defp decide(%{status: :confirmed}, _code, _meta), do: :ignore

  defp decide(request, 0, meta) do
    if meta[:amount_cents] && meta.amount_cents != request.amount_cents do
      Logger.error(
        "M-Pesa amount mismatch on request #{request.id}: expected #{request.amount_cents}, got #{meta.amount_cents}"
      )

      {:update, %{status: :failed}}
    else
      {:update,
       %{
         status: :confirmed,
         receipt_number: meta[:receipt],
         paid_at: usec(meta[:paid_at] || DateTime.utc_now())
       }}
    end
  end

  defp decide(%{status: :pending}, code, _meta) when code in [1019, 1037],
    do: {:update, %{status: :timed_out}}

  defp decide(%{status: :pending}, 4999, _meta), do: :ignore

  defp decide(%{status: :pending}, _code, _meta),
    do: {:update, %{status: :failed}}

  defp decide(_request, _code, _meta), do: :ignore

  ## Claiming (called by Sales)

  @doc "Read-only check that a request can pay for this sale. Run before the sale transaction."
  def fetch_claimable(sale_id, request_id, amount_cents) do
    case get_request(request_id) do
      nil -> {:error, :mpesa_request_not_found}
      %{sale_id: other} when other != sale_id -> {:error, :mpesa_wrong_sale}
      %{status: status} when status != :confirmed -> {:error, :mpesa_payment_not_confirmed}
      %{amount_cents: a} when a != amount_cents -> {:error, :mpesa_amount_mismatch}
      %{claimed_at: %DateTime{}} -> {:error, :mpesa_already_used}
      request -> {:ok, request}
    end
  end

  @doc "Marks a request as used by a sale. Locks the row, so it can only happen once."
  def claim(repo, request_id) do
    request = repo.one!(from r in MpesaRequest, where: r.id == ^request_id, lock: "FOR UPDATE")

    cond do
      request.claimed_at -> {:error, :mpesa_already_used}
      request.status != :confirmed -> {:error, :mpesa_payment_not_confirmed}
      true -> request |> Ecto.Changeset.change(claimed_at: DateTime.utc_now()) |> repo.update()
    end
  end

  ## Parsing helpers

  # Failed callbacks carry no CallbackMetadata.
  defp parse_metadata(cb) do
    items = get_in(cb, ["CallbackMetadata", "Item"]) || []
    values = Map.new(items, fn item -> {item["Name"], item["Value"]} end)

    %{
      amount_cents: to_cents(values["Amount"]),
      receipt: values["MpesaReceiptNumber"] && to_string(values["MpesaReceiptNumber"]),
      paid_at: parse_date(values["TransactionDate"])
    }
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {i, _} -> i
      :error -> -1
    end
  end

  def to_cents(v) when is_integer(v), do: v * 100
  def to_cents(v) when is_float(v), do: round(v * 100)

  def to_cents(v) when is_binary(v) do
    case Decimal.parse(v) do
      {d, _} -> d |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
      :error -> nil
    end
  end

  def to_cents(_), do: nil

  # "20191219102115" in East Africa Time -> UTC
  def parse_date(v) when is_integer(v), do: parse_date(Integer.to_string(v))

  def parse_date(v) when is_binary(v) do
    with [_, y, mo, d, h, mi, s] <- Regex.run(~r/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/, v),
         [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1),
         {:ok, naive} <- NaiveDateTime.new(y, mo, d, h, mi, s) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-3 * 3600, :second)
    else
      _ -> nil
    end
  end

  def parse_date(_), do: nil

  # utc_datetime_usec columns reject values without microsecond precision.
  def usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp age(%{inserted_at: inserted}), do: DateTime.diff(DateTime.utc_now(), inserted, :second)
end
