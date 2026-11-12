defmodule PosWeb.Plugs.RequireRole do
  @moduledoc """
  Minimum-role check. Roles are ordered cashier < supervisor < manager < admin,
  so `plug RequireRole, :manager` allows managers and admins.
  """
  @behaviour Plug
  import Plug.Conn

  alias Pos.Accounts.User
  alias PosWeb.ErrorResponse

  @impl true
  def init(min_role), do: min_role

  @impl true
  def call(conn, min_role) do
    user = conn.assigns[:current_user]

    if user && rank(user.role) >= rank(min_role) do
      conn
    else
      conn
      |> ErrorResponse.respond(403, "forbidden", "Requires #{min_role} role or higher")
      |> halt()
    end
  end

  defp rank(role), do: Enum.find_index(User.roles(), &(&1 == role))
end
