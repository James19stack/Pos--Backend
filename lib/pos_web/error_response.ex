defmodule PosWeb.ErrorResponse do
  @moduledoc "One error shape for the whole API: {\"error\": {code, message, details}}."

  def respond(conn, status, code, message, details \\ nil) do
    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.json(%{error: %{code: code, message: message, details: details}})
  end
end
