# Replace the generated router with this. If your generated file has a
# `dev_routes` block (LiveDashboard), keep that block at the bottom.
defmodule PosWeb.Router do
  use PosWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PosWeb.ApiSpec
  end

  pipeline :authenticated do
    plug PosWeb.Plugs.Authenticate
  end

  # API docs: Swagger UI at /api/swagger, raw spec at /api/openapi
  scope "/api" do
    pipe_through :api
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
    get "/swagger", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  scope "/api", PosWeb do
    pipe_through :api
    post "/auth/login", AuthController, :login
    # Called by Safaricom: no JWT, protected by the secret in the URL.
    # The path avoids the word "mpesa" as a precaution.
    post "/callbacks/daraja/:secret", DarajaCallbackController, :stk
    post "/callbacks/daraja/:secret/c2b/confirmation", DarajaC2BController, :confirmation
    post "/callbacks/daraja/:secret/c2b/validation", DarajaC2BController, :validation
  end

  scope "/api", PosWeb do
    pipe_through [:api, :authenticated]

    get "/me", AuthController, :me
    get "/catalog", CatalogController, :index
    get "/products/barcode/:code", CatalogController, :by_barcode

    post "/sales", SaleController, :create
    # "review" must come before ":id" or it would be read as a sale id
    get "/sales/review", SaleController, :review
    get "/sales/receipt/:receipt_no", ReversalController, :lookup
    post "/sales/:id/void", ReversalController, :void
    post "/sales/:id/returns", ReversalController, :create_return
    get "/sales/:id/returns", ReversalController, :list_returns
    get "/sales/:id", SaleController, :show
    get "/sales/:id/etims", EtimsController, :show
    post "/sales/:id/etims/submit", EtimsController, :submit
    get "/etims/pending", EtimsController, :pending

    get "/categories", CategoryController, :index
    post "/categories", CategoryController, :create
    patch "/categories/:id", CategoryController, :update

    get "/products", ProductController, :index
    post "/products", ProductController, :create
    post "/products/import", ProductController, :import_csv
    patch "/products/:id", ProductController, :update
    get "/products/:id/movements", ProductController, :movements

    post "/stock/receipts", StockController, :create_receipt
    post "/stock/adjustments", StockController, :adjust
    get "/stock/low", StockController, :low

    post "/shifts/open", ShiftController, :open
    get "/shifts/current", ShiftController, :current
    # "current/report" must come before ":id/report"
    get "/shifts/current/report", ShiftController, :current_report
    post "/shifts/close", ShiftController, :close
    get "/shifts/pending", ShiftController, :pending
    get "/shifts/:id/report", ShiftController, :report
    post "/shifts/:id/approve", ShiftController, :approve

    post "/mpesa/stk", MpesaController, :initiate
    get "/mpesa/unclaimed", MpesaController, :unclaimed
    get "/mpesa/payments/:code", MpesaController, :payment
    get "/mpesa/requests/:id", MpesaController, :show
    post "/mpesa/requests/:id/check", MpesaController, :check
  end
end
