defmodule PosWeb.EtimsController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pos.{Etims, Sales}
  alias PosWeb.{ApiJSON, ErrorResponse, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  plug PosWeb.Plugs.RequireRole, :supervisor when action in [:submit]
  plug PosWeb.Plugs.RequireRole, :manager when action in [:pending]
  tags ["eTIMS"]

  @id_param [id: [in: :path, description: "Sale id", schema: %Schema{type: :string, format: :uuid}]]

  operation :show,
    summary: "KRA invoice status for a sale",
    description: "Pending until filed. Once accepted it carries the receipt number, internal data and signature that belong on the printed receipt. `mock: true` means a stand-in, not KRA: print TEST MODE.",
    parameters: @id_param,
    responses: %{200 => {"Invoice", "application/json", Schemas.GenericResponse}, 404 => {"Not found", "application/json", Schemas.Error}}

  def show(conn, %{id: id}) do
    with {:ok, sale} <- visible_sale(conn, id),
         %{} = invoice <- Etims.get_invoice_for_sale(sale.id) || {:error, :not_found} do
      json(conn, %{data: ApiJSON.etims(invoice)})
    end
  end

  operation :submit,
    summary: "File the invoice now",
    description: "Supervisors and above. For a pending invoice the background job has not filed yet. Safe to repeat: an accepted invoice is never sent twice.",
    parameters: @id_param,
    responses: %{
      200 => {"Invoice", "application/json", Schemas.GenericResponse},
      502 => {"KRA did not accept it yet", "application/json", Schemas.Error}
    }

  def submit(conn, %{id: id}) do
    with {:ok, sale} <- visible_sale(conn, id),
         %{} = invoice <- Etims.get_invoice_for_sale(sale.id) || {:error, :not_found} do
      case Etims.submit(invoice.id) do
        {:ok, filed} -> json(conn, %{data: ApiJSON.etims(filed)})
        {:error, reason} -> ErrorResponse.respond(conn, 502, "etims_unavailable", "The invoice is not filed yet: #{inspect(reason)}")
      end
    end
  end

  operation :pending,
    summary: "Invoices not yet filed with KRA",
    description: "Pending for more than two minutes. Managers and above: this is the compliance watch-list.",
    responses: %{200 => {"Invoices", "application/json", Schemas.GenericResponse}}

  def pending(conn, _params), do: json(conn, %{data: Enum.map(Etims.list_pending(), &ApiJSON.etims/1)})

  defp visible_sale(conn, id) do
    user = conn.assigns.current_user

    case Sales.get_sale(id) do
      nil -> {:error, :not_found}
      %{cashier_id: owner} when user.role == :cashier and owner != user.id -> {:error, :not_found}
      sale -> {:ok, sale}
    end
  end
end
