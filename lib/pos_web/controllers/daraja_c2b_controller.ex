defmodule PosWeb.DarajaC2BController do
  @moduledoc """
  Safaricom's notifications for payments made to the till/paybill. No JWT is possible,
  so the URL carries a secret. We never reject on validation: if the money reached the
  till, we want to know about it.
  """
  use PosWeb, :controller
  require Logger

  alias Pos.Payments.C2B

  def confirmation(conn, %{"secret" => secret} = params) do
    with_secret(conn, secret, fn ->
      case C2B.record_confirmation(Map.delete(params, "secret")) do
        {:ok, payment} -> Logger.info("C2B payment recorded: #{payment.trans_id}")
        :ignored -> Logger.warning("C2B confirmation ignored")
      end

      json(conn, %{"ResultCode" => 0, "ResultDesc" => "Success"})
    end)
  end

  def validation(conn, %{"secret" => secret}) do
    with_secret(conn, secret, fn ->
      json(conn, %{"ResultCode" => "0", "ResultDesc" => "Accepted"})
    end)
  end

  defp with_secret(conn, secret, fun) do
    expected = Application.get_env(:pos, :daraja, [])[:callback_secret]

    if is_binary(expected) and expected != "" and Plug.Crypto.secure_compare(secret, expected),
      do: fun.(),
      else: send_resp(conn, 404, "")
  end
end
