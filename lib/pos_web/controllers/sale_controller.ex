defmodule PosWeb.SaleController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pos.Sales
  alias PosWeb.{ApiJSON, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  plug PosWeb.Plugs.RequireRole, :manager when action in [:review]
  tags(["Sales"])

  operation(:create,
    summary: "Record a sale",
    description: """
    Records a completed sale in one database transaction: the sale, its items,
    payments and stock movements.

    **Idempotent.** The till generates the sale `id`. Sending the same id again
    returns the original sale (200) and changes nothing, so offline queues can
    retry safely. A new sale returns 201.

    Prices, VAT and totals are computed by the server. Payments must add up to
    the total exactly. If stock would go negative the sale still succeeds and is
    flagged `needs_review`.
    """,
    request_body: {"Sale to record", "application/json", Schemas.CreateSaleRequest},
    responses: %{
      200 => {"Sale already recorded (duplicate id)", "application/json", Schemas.SaleResponse},
      201 => {"Sale recorded", "application/json", Schemas.SaleResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error},
      422 => {"Invalid sale", "application/json", Schemas.Error}
    }
  )

  def create(conn, _params) do
    attrs = conn.body_params
    cashier = conn.assigns.current_user
    existed? = Sales.get_sale(attrs.id) != nil

    with {:ok, sale} <- Sales.create_sale(attrs, cashier) do
      conn
      |> put_status(if existed?, do: :ok, else: :created)
      |> json(%{data: ApiJSON.sale(sale)})
    end
  end

  operation(:show,
    summary: "Get a sale",
    description: "Cashiers can only see their own sales. Supervisors and above can see any.",
    parameters: [
      id: [in: :path, description: "Sale id", schema: %Schema{type: :string, format: :uuid}]
    ],
    responses: %{
      200 => {"Sale", "application/json", Schemas.SaleResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error},
      404 => {"Not found", "application/json", Schemas.Error}
    }
  )

  def show(conn, %{id: id}) do
    user = conn.assigns.current_user

    case Sales.get_sale(id) do
      nil -> {:error, :not_found}
      %{cashier_id: owner} when user.role == :cashier and owner != user.id -> {:error, :not_found}
      sale -> json(conn, %{data: ApiJSON.sale(sale)})
    end
  end

  operation(:review,
    summary: "Sales needing review",
    description: "Sales flagged because stock went negative. Managers and admins only.",
    responses: %{
      200 => {"Flagged sales", "application/json", Schemas.SalesResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error},
      403 => {"Requires manager role", "application/json", Schemas.Error}
    }
  )

  def review(conn, _params) do
    json(conn, %{data: Enum.map(Sales.list_sales_needing_review(), &ApiJSON.sale/1)})
  end
end
