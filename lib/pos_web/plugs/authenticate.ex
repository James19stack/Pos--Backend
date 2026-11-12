defmodule PosWeb.Plugs.Authenticate do
  @behaviour Plug
  import Plug.Conn

  alias Pos.Accounts
  alias PosWeb.Auth.Token
  alias PosWeb.ErrorResponse

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Token.verify(token),
         %{active: true} = user <- Accounts.get_user(claims["sub"]) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> ErrorResponse.respond(401, "unauthorized", "Missing, invalid or expired token")
        |> halt()
    end
  end
end
