defmodule Pos.Payments.Daraja.HTTP do
  @moduledoc """
  Real Daraja client. Notes:
  - Amount is whole shillings; the timestamp is East Africa Time (UTC+3).
  - STK pushes are NEVER retried after a timeout: a retry could prompt the customer twice.
    The one exception is an "invalid token" rejection, which happens BEFORE any prompt is
    sent, so repeating the call once with a fresh token is safe.
  - Request bodies contain the passkey (inside Password), so they are never logged.
  """
  @behaviour Pos.Payments.Daraja

  @token_errors ["404.001.03", "401.002.01"]

  @impl true
  def stk_push(params) do
    cfg = config()
    ts = timestamp()

    body = %{
      "BusinessShortCode" => cfg.shortcode,
      "Password" => password(cfg, ts),
      "Timestamp" => ts,
      "TransactionType" => cfg.transaction_type,
      "Amount" => params.amount,
      "PartyA" => params.phone,
      "PartyB" => cfg.party_b,
      "PhoneNumber" => params.phone,
      "CallBackURL" => params.callback_url,
      "AccountReference" => params.account_reference,
      "TransactionDesc" => params.description
    }

    with :ok <- check_config(cfg),
         {:ok, %{status: 200, body: %{"ResponseCode" => "0"} = resp}} <-
           authed_post(cfg, "/mpesa/stkpush/v1/processrequest", body, retry: false) do
      {:ok,
       %{
         checkout_request_id: resp["CheckoutRequestID"],
         merchant_request_id: resp["MerchantRequestID"]
       }}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def query(checkout_request_id) do
    cfg = config()
    ts = timestamp()

    body = %{
      "BusinessShortCode" => cfg.shortcode,
      "Password" => password(cfg, ts),
      "Timestamp" => ts,
      "CheckoutRequestID" => checkout_request_id
    }

    with :ok <- check_config(cfg),
         {:ok, %{status: 200, body: %{"ResultCode" => code} = resp}} <-
           authed_post(cfg, "/mpesa/stkpushquery/v1/query", body, []),
         {int, _} <- Integer.parse(to_string(code)) do
      {:ok, %{result_code: int, result_desc: resp["ResultDesc"]}}
    else
      # Daraja errors while a transaction is still processing; callers treat any error as "unknown".
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unexpected_response}
    end
  end

  @impl true
  def register_c2b_urls(%{confirmation_url: confirmation, validation_url: validation}) do
    cfg = config()

    body = %{
      "ShortCode" => cfg.c2b_shortcode,
      # We never block payments: if validation is unreachable, let Safaricom complete them.
      "ResponseType" => "Completed",
      "ConfirmationURL" => confirmation,
      "ValidationURL" => validation
    }

    with :ok <- check_config(cfg),
         {:ok, %{status: 200, body: resp}} <-
           authed_post(cfg, "/mpesa/c2b/v2/registerurl", body, retry: false) do
      {:ok, resp}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Sandbox only: makes Safaricom send a fake customer payment to our Confirmation URL."
  def simulate_c2b(%{amount: amount, msisdn: msisdn, bill_ref: bill_ref}) do
    cfg = config()
    buy_goods? = cfg.transaction_type == "CustomerBuyGoodsOnline"

    body = %{
      "ShortCode" => cfg.c2b_shortcode,
      "CommandID" => if(buy_goods?, do: "CustomerBuyGoodsOnline", else: "CustomerPayBillOnline"),
      "Amount" => amount,
      "Msisdn" => msisdn
    }

    # Paybill needs an account reference; Buy Goods must not have one.
    body = if buy_goods?, do: body, else: Map.put(body, "BillRefNumber", bill_ref)

    if cfg.env == :production do
      {:error, :simulation_is_sandbox_only}
    else
      with :ok <- check_config(cfg),
           {:ok, %{status: 200, body: resp}} <-
             authed_post(cfg, "/mpesa/c2b/v2/simulate", body, retry: false) do
        {:ok, resp}
      else
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  ## Authenticated POST. Daraja reports a bad or expired token as HTTP 404 (code 404.001.03).

  defp authed_post(cfg, path, body, opts) do
    case do_post(cfg, path, body, opts) do
      {:ok, %{body: %{"errorCode" => code}}} when code in @token_errors ->
        forget_token(cfg)
        do_post(cfg, path, body, opts)

      other ->
        other
    end
  end

  defp do_post(cfg, path, body, opts) do
    with {:ok, token} <- token(cfg) do
      Req.post(
        cfg.base_url <> path,
        [json: body, auth: {:bearer, token}, receive_timeout: 15_000] ++ opts
      )
    end
  end

  ## OAuth token, cached until shortly before it expires

  defp token(cfg) do
    now = System.os_time(:second)

    case :persistent_term.get(token_key(cfg), nil) do
      {token, expires_at} when expires_at > now + 30 ->
        {:ok, token}

      _ ->
        case Req.get(cfg.base_url <> "/oauth/v1/generate",
               params: [grant_type: "client_credentials"],
               auth: {:basic, "#{cfg.consumer_key}:#{cfg.consumer_secret}"},
               receive_timeout: 15_000
             ) do
          {:ok, %{status: 200, body: %{"access_token" => token} = resp}} ->
            ttl =
              resp |> Map.get("expires_in", "3599") |> to_string() |> Integer.parse() |> elem(0)

            :persistent_term.put(token_key(cfg), {token, now + ttl})
            {:ok, token}

          {:ok, %{status: status}} ->
            {:error, {:auth_failed, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp token_key(cfg), do: {__MODULE__, :token, cfg.base_url}
  defp forget_token(cfg), do: :persistent_term.erase(token_key(cfg))

  ## Helpers

  defp timestamp do
    DateTime.utc_now() |> DateTime.add(3 * 3600, :second) |> Calendar.strftime("%Y%m%d%H%M%S")
  end

  defp password(cfg, ts), do: Base.encode64(cfg.shortcode <> cfg.passkey <> ts)

  defp check_config(%{consumer_key: k, consumer_secret: s, passkey: p, shortcode: c})
       when is_binary(k) and is_binary(s) and is_binary(p) and is_binary(c),
       do: :ok

  defp check_config(_), do: {:error, :daraja_not_configured}

  defp config do
    c = Application.get_env(:pos, :daraja, [])

    %{
      base_url:
        if(c[:env] == :production,
          do: "https://api.safaricom.co.ke",
          else: "https://sandbox.safaricom.co.ke"
        ),
      consumer_key: blank_to_nil(c[:consumer_key]),
      consumer_secret: blank_to_nil(c[:consumer_secret]),
      shortcode: blank_to_nil(c[:shortcode]),
      # Sandbox C2B uses a different test shortcode from STK Push; in production they match.
      c2b_shortcode: blank_to_nil(c[:c2b_shortcode]) || blank_to_nil(c[:shortcode]),
      env: c[:env],
      passkey: blank_to_nil(c[:passkey]),
      transaction_type: blank_to_nil(c[:transaction_type]) || "CustomerPayBillOnline",
      # PayBill: same as the shortcode. Buy Goods: the till number.
      party_b: blank_to_nil(c[:party_b]) || blank_to_nil(c[:shortcode])
    }
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
