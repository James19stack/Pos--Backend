defmodule PosWeb.ProductController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pos.{Catalog, Inventory}
  alias PosWeb.{ApiJSON, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  plug PosWeb.Plugs.RequireRole, :supervisor when action in [:index, :movements]
  plug PosWeb.Plugs.RequireRole, :manager when action in [:create, :update, :import_csv]
  tags ["Products"]

  @id_param [id: [in: :path, description: "Product id", schema: %Schema{type: :string, format: :uuid}]]

  operation :index,
    summary: "Search products",
    description: "By name, sku or exact barcode, with current stock. Supervisors and above.",
    parameters: [
      q: [in: :query, description: "Search text", type: :string, required: false],
      limit: [in: :query, description: "Max 200, default 50", type: :integer, required: false],
      offset: [in: :query, description: "For paging", type: :integer, required: false]
    ],
    responses: %{200 => {"Products", "application/json", Schemas.GenericResponse}}

  def index(conn, params) do
    products = Catalog.list_products(q: params[:q], limit: params[:limit], offset: params[:offset])
    json(conn, %{data: Enum.map(products, &ApiJSON.product_admin/1)})
  end

  operation :create,
    summary: "Add a product",
    description: "Managers and above. `vat_code` is the tax code (A to E). Prices are VAT-inclusive cents.",
    request_body: {"Product", "application/json", Schemas.ProductInput},
    responses: %{
      201 => {"Created", "application/json", Schemas.GenericResponse},
      422 => {"Invalid", "application/json", Schemas.Error}
    }

  def create(conn, _params) do
    body = conn.body_params

    with {:ok, vat} <- vat_by_code(body.vat_code),
         {:ok, product} <- Catalog.register_product(conn.assigns.current_user, attrs(body, vat), Map.get(body, :barcodes, [])) do
      conn |> put_status(:created) |> json(%{data: ApiJSON.product_admin(product)})
    end
  end

  operation :update,
    summary: "Change a product",
    description: "Managers and above. Every change to price, cost, VAT, name or status is recorded in the audit log with old and new values. Send only what changes; `active: false` retires a product.",
    parameters: @id_param,
    request_body: {"Fields to change", "application/json", Schemas.ProductUpdate},
    responses: %{
      200 => {"Updated", "application/json", Schemas.GenericResponse},
      404 => {"Not found", "application/json", Schemas.Error}
    }

  def update(conn, %{id: id}) do
    body = conn.body_params

    with %{} = product <- Catalog.get_product(id) || {:error, :not_found},
         {:ok, attrs} <- update_attrs(body),
         {:ok, updated} <- Catalog.update_product(conn.assigns.current_user, product, attrs) do
      json(conn, %{data: ApiJSON.product_admin(updated)})
    end
  end

  operation :import_csv,
    summary: "Import a price list (CSV)",
    description: """
    Send the file's text as `csv`. Columns: sku, name, price, vat_code (required); barcode
    (several with |), cost, weighed, unit, reorder_level, opening_stock. Prices in shillings.
    Existing skus are updated (price changes audited, stock untouched); new ones are created.
    All-or-nothing: any bad row means nothing is saved and every problem is listed with its
    row number. Use `dry_run: true` to check a file first.
    """,
    request_body: {"CSV text", "application/json", Schemas.ProductImportRequest},
    responses: %{
      200 => {"Result", "application/json", Schemas.GenericResponse},
      422 => {"File has problems", "application/json", Schemas.Error}
    }

  def import_csv(conn, _params) do
    body = conn.body_params

    with {:ok, summary} <- Catalog.Import.run(conn.assigns.current_user, body.csv, dry_run: Map.get(body, :dry_run, false)) do
      json(conn, %{data: summary})
    end
  end

  operation :movements,
    summary: "Stock history for a product",
    description: "Every stock movement, newest first. Supervisors and above.",
    parameters: @id_param,
    responses: %{200 => {"Movements", "application/json", Schemas.GenericResponse}, 404 => {"Not found", "application/json", Schemas.Error}}

  def movements(conn, %{id: id}) do
    with %{} = product <- Catalog.get_product(id) || {:error, :not_found} do
      json(conn, %{data: Enum.map(Inventory.movements(product.id), &ApiJSON.movement/1)})
    end
  end

  defp vat_by_code(code) do
    case Catalog.get_vat_rate_by_code(String.upcase(code)) do
      nil -> {:error, :unknown_vat_code}
      vat -> {:ok, vat}
    end
  end

  defp attrs(body, vat) do
    body |> Map.take([:sku, :name, :price_cents, :cost_cents, :is_weighed, :unit, :reorder_level, :active, :etims_item_cls_cd, :pkg_unit_cd, :qty_unit_cd, :category_id]) |> Map.put(:vat_rate_id, vat.id)
  end

  defp update_attrs(body) do
    base = Map.take(body, [:name, :price_cents, :cost_cents, :is_weighed, :unit, :reorder_level, :active, :etims_item_cls_cd, :pkg_unit_cd, :qty_unit_cd, :category_id])

    case Map.get(body, :vat_code) do
      nil ->
        {:ok, base}

      code ->
        with {:ok, vat} <- vat_by_code(code), do: {:ok, Map.put(base, :vat_rate_id, vat.id)}
    end
  end
end
