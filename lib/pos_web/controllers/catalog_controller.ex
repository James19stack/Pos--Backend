defmodule PosWeb.CatalogController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Pos.Catalog
  alias PosWeb.{ApiJSON, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  tags(["Catalog"])

  operation(:index,
    summary: "Full catalogue",
    description:
      "Every active product with barcodes and VAT. The till caches this locally (IndexedDB) so it can scan offline.",
    responses: %{
      200 => {"Catalogue", "application/json", Schemas.CatalogResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error}
    }
  )

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Catalog.list_catalog(), &ApiJSON.product/1)})
  end

  operation(:by_barcode,
    summary: "Look up a product by barcode",
    parameters: [
      code: [in: :path, description: "Scanned barcode", type: :string, example: "6161100000001"]
    ],
    responses: %{
      200 => {"Product", "application/json", Schemas.ProductResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error},
      404 => {"No active product with that barcode", "application/json", Schemas.Error}
    }
  )

  def by_barcode(conn, %{code: code}) do
    case Catalog.get_product_by_barcode(code) do
      nil -> {:error, :not_found}
      product -> json(conn, %{data: ApiJSON.product(product)})
    end
  end
end
