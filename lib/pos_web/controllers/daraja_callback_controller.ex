defmodule PosWeb.DarajaCallbackController do
  @moduledoc """
  Called by Safaricom, so it cannot use a JWT. Daraja does not sign callbacks, so we
  rely on: a secret in the URL, matching the CheckoutRequestID to a request WE created,
  checking the amount, and the reconciler, which asks Daraja directly.
  """
  use PosWeb, :controller
  require Logger

  alias Pos.Payments.Mpesa

  def stk(conn, %{"secret" => secret} = params) do
    expected = Application.fetch_env!(:pos, :daraja)[:callback_secret]

    if is_binary(expected) and expected != "" and Plug.Crypto.secure_compare(secret, expected) do
      case Mpesa.handle_callback(Map.delete(params, "secret")) do
        {:ok, request} ->
          Logger.info("Daraja callback applied to request #{request.id}: #{request.status}")

        :ignored ->
          Logger.info("Daraja callback ignored")
      end

      # Always acknowledge quickly, or Safaricom retries.
      json(conn, %{"ResultCode" => 0, "ResultDesc" => "Accepted"})
    else
      send_resp(conn, 404, "")
    end
  end
end
