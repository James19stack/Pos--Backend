defmodule PosWeb.MpesaController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pos.Payments.{C2B, Mpesa}
  alias PosWeb.{ApiJSON, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  plug PosWeb.Plugs.RequireRole, :manager when action in [:unclaimed]
  tags(["M-Pesa"])

  operation(:initiate,
    summary: "Send an M-Pesa prompt to the customer's phone",
    description: """
    Starts an STK Push for a sale the till has not recorded yet. `sale_id` is the same
    UUID the till will use for `POST /api/sales`. The amount must be whole shillings
    (M-Pesa cannot charge cents), so take the remainder in cash.

    Idempotent: repeating the call for the same sale, phone and amount returns the live
    request (200) and sends no second prompt. Poll `GET /api/mpesa/requests/{id}` until
    `status` is `confirmed`, `failed` or `timed_out`, then record the sale with an
    `mpesa` payment that names this request.
    """,
    request_body: {"Payment to request", "application/json", Schemas.MpesaRequestInput},
    responses: %{
      200 => {"Existing request for this sale", "application/json", Schemas.MpesaRequestResponse},
      201 => {"Prompt sent", "application/json", Schemas.MpesaRequestResponse},
      401 => {"Missing or invalid token", "application/json", Schemas.Error},
      422 =>
        {"Invalid phone or amount, or another payment is in progress", "application/json",
         Schemas.Error},
      502 => {"Could not reach M-Pesa", "application/json", Schemas.Error}
    }
  )

  def initiate(conn, _params) do
    with {:ok, request, kind} <- Mpesa.initiate(conn.assigns.current_user, conn.body_params) do
      conn
      |> put_status(if kind == :created, do: :created, else: :ok)
      |> json(%{data: ApiJSON.mpesa_request(request)})
    end
  end

  operation(:show,
    summary: "Check an M-Pesa request",
    description: "Cashiers see their own requests; supervisors and above see all.",
    parameters: [
      id: [in: :path, description: "Request id", schema: %Schema{type: :string, format: :uuid}]
    ],
    responses: %{
      200 => {"Request", "application/json", Schemas.MpesaRequestResponse},
      404 => {"Not found", "application/json", Schemas.Error}
    }
  )

  def show(conn, %{id: id}) do
    with {:ok, request} <- visible(conn, id) do
      json(conn, %{data: ApiJSON.mpesa_request(request)})
    end
  end

  operation(:check,
    summary: "Ask Daraja now",
    description:
      "For when the customer says they paid but the callback has not arrived. Queries Daraja and updates the request.",
    parameters: [
      id: [in: :path, description: "Request id", schema: %Schema{type: :string, format: :uuid}]
    ],
    responses: %{
      200 => {"Request after the check", "application/json", Schemas.MpesaRequestResponse},
      404 => {"Not found", "application/json", Schemas.Error}
    }
  )

  def check(conn, %{id: id}) do
    with {:ok, request} <- visible(conn, id),
         {:ok, request} <- Mpesa.reconcile(request) do
      json(conn, %{data: ApiJSON.mpesa_request(request)})
    end
  end

  operation(:unclaimed,
    summary: "Paid but no sale",
    description:
      "Confirmed M-Pesa payments older than 5 minutes that no sale used: the customer paid and the till never recorded the sale. Managers and above.",
    responses: %{
      200 => {"Unclaimed payments", "application/json", Schemas.MpesaRequestsResponse},
      403 => {"Requires manager role", "application/json", Schemas.Error}
    }
  )

  def unclaimed(conn, _params) do
    json(conn, %{data: Enum.map(Mpesa.list_unclaimed(), &ApiJSON.mpesa_request/1)})
  end

  operation(:payment,
    summary: "Look up a payment the customer made straight to the till or paybill",
    description:
      "By the transaction code in the customer's M-Pesa SMS. 404 means Safaricom has not told us about it (yet), so a fake SMS fails here.",
    parameters: [
      code: [in: :path, description: "Transaction code", type: :string, example: "RKTQDM7W6S"]
    ],
    responses: %{
      200 => {"Payment", "application/json", Schemas.C2BPaymentResponse},
      404 => {"Not received", "application/json", Schemas.Error}
    }
  )

  def payment(conn, %{code: code}) do
    case C2B.get_by_code(code) do
      nil -> {:error, :not_found}
      payment -> json(conn, %{data: ApiJSON.c2b_payment(payment)})
    end
  end

  defp visible(conn, id) do
    user = conn.assigns.current_user

    case Mpesa.get_request(id) do
      nil -> {:error, :not_found}
      %{user_id: owner} when user.role == :cashier and owner != user.id -> {:error, :not_found}
      request -> {:ok, request}
    end
  end
end
