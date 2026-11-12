defmodule PosWeb.AuthController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Pos.Accounts
  alias PosWeb.{ApiJSON, Schemas}
  alias PosWeb.Auth.Token

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  tags(["Auth"])

  operation(:login,
    summary: "Log in",
    description: "Exchange email and password for a JWT valid for one shift (12 hours).",
    security: [],
    request_body: {"Credentials", "application/json", Schemas.LoginRequest},
    responses: %{
      200 => {"Logged in", "application/json", Schemas.LoginResponse},
      401 => {"Wrong email or password", "application/json", Schemas.Error},
      422 => {"Invalid request body", "application/json", Schemas.Error}
    }
  )

  def login(conn, _params) do
    %{email: email, password: password} = conn.body_params

    with {:ok, user} <- Accounts.authenticate(email, password),
         {:ok, token, expires_in} <- Token.issue(user) do
      json(conn, %{data: %{token: token, expires_in: expires_in, user: ApiJSON.user(user)}})
    end
  end

  operation(:me,
    summary: "Current user",
    responses: %{
      200 => {"The logged-in user", "application/json", Schemas.UserResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error}
    }
  )

  def me(conn, _params) do
    json(conn, %{data: ApiJSON.user(conn.assigns.current_user)})
  end
end
