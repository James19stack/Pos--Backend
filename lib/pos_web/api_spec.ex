defmodule PosWeb.ApiSpec do
  @moduledoc "Builds the OpenAPI document from the router and controller specs."
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(PosWeb.Endpoint)],
      info: %Info{
        title: "Supermarket POS API",
        version: "0.1.0",
        description: """
        Backend for the till and back-office apps.

        All money is integer cents (KES x 100) and prices are VAT-inclusive.
        Log in at `POST /api/auth/login`, then click **Authorize** and paste the token.
        """
      },
      paths: Paths.from_router(PosWeb.Router),
      components: %Components{
        securitySchemes: %{
          "authorization" => %SecurityScheme{type: "http", scheme: "bearer", bearerFormat: "JWT"}
        }
      },
      security: [%{"authorization" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
