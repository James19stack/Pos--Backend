defmodule PosWeb.CategoryController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pos.Catalog
  alias PosWeb.{ApiJSON, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  plug PosWeb.Plugs.RequireRole, :supervisor when action in [:index]
  plug PosWeb.Plugs.RequireRole, :manager when action in [:create, :update]
  tags ["Categories"]

  operation :index,
    summary: "List categories",
    responses: %{200 => {"Categories", "application/json", Schemas.GenericResponse}}

  def index(conn, _params), do: json(conn, %{data: Enum.map(Catalog.list_categories(), &ApiJSON.category/1)})

  operation :create,
    summary: "Add a category",
    description: "Managers and above. The KRA codes are defaults for every product in the category; a product's own codes win.",
    request_body: {"Category", "application/json", Schemas.CategoryInput},
    responses: %{201 => {"Created", "application/json", Schemas.GenericResponse}, 422 => {"Invalid", "application/json", Schemas.Error}}

  def create(conn, _params) do
    with {:ok, category} <- Catalog.create_category(conn.assigns.current_user, conn.body_params) do
      conn |> put_status(:created) |> json(%{data: ApiJSON.category(category)})
    end
  end

  operation :update,
    summary: "Change a category",
    description: "Managers and above, audited. Products already registered with KRA keep the codes they were registered with.",
    parameters: [id: [in: :path, description: "Category id", schema: %Schema{type: :string, format: :uuid}]],
    request_body: {"Fields to change", "application/json", Schemas.CategoryInput},
    responses: %{200 => {"Updated", "application/json", Schemas.GenericResponse}, 404 => {"Not found", "application/json", Schemas.Error}}

  def update(conn, %{id: id}) do
    with %{} = category <- Catalog.get_category(id) || {:error, :not_found},
         {:ok, updated} <- Catalog.update_category(conn.assigns.current_user, category, conn.body_params) do
      json(conn, %{data: ApiJSON.category(updated)})
    end
  end
end
