defmodule PosWeb.ShiftController do
  use PosWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pos.Shifts
  alias PosWeb.{ApiJSON, Schemas}

  action_fallback PosWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
  plug PosWeb.Plugs.RequireRole, :manager when action in [:pending, :approve]
  tags(["Shifts"])

  @id_param [
    id: [in: :path, description: "Shift id", schema: %Schema{type: :string, format: :uuid}]
  ]

  operation(:open,
    summary: "Open a shift",
    description:
      "Starts a shift with the cash float counted into the drawer. One open shift per cashier and per till. Nothing can be sold without one.",
    request_body: {"Opening float", "application/json", Schemas.OpenShiftRequest},
    responses: %{
      201 => {"Shift opened", "application/json", Schemas.ShiftResponse},
      422 => {"Already open, or the till is in use", "application/json", Schemas.Error}
    }
  )

  def open(conn, _params) do
    attrs = conn.body_params

    with {:ok, shift} <-
           Shifts.open_shift(conn.assigns.current_user, %{
             opening_float_cents: attrs.opening_float_cents,
             device_id: Map.get(attrs, :device_id)
           }) do
      conn |> put_status(:created) |> json(%{data: ApiJSON.shift(shift)})
    end
  end

  operation(:current,
    summary: "My open shift",
    description:
      "`data` is null when no shift is open. The till uses this to decide between the open-shift screen and the till.",
    responses: %{200 => {"Open shift or null", "application/json", Schemas.ShiftResponse}}
  )

  def current(conn, _params) do
    shift = Shifts.get_open_shift(conn.assigns.current_user)
    json(conn, %{data: shift && ApiJSON.shift(shift)})
  end

  operation(:current_report,
    summary: "X report for my open shift",
    description:
      "A snapshot without closing. Cashiers do not see expected cash (the cash-up is blind); supervisors and above do.",
    responses: %{
      200 => {"Report", "application/json", Schemas.ShiftReportResponse},
      422 => {"No open shift", "application/json", Schemas.Error}
    }
  )

  def current_report(conn, _params) do
    user = conn.assigns.current_user

    with {:ok, shift} <- Shifts.fetch_open(user) do
      json(conn, %{data: blind(Shifts.report(shift), user)})
    end
  end

  operation(:close,
    summary: "Cash up and close my shift",
    description: """
    Blind cash-up: send what you counted in the drawer (float included). The server
    compares it with float + cash taken. A difference over KES 500 leaves the shift
    `pending_approval` until a manager signs it off. Returns the shift with its Z report.
    """,
    request_body: {"Counted cash", "application/json", Schemas.CloseShiftRequest},
    responses: %{
      200 => {"Closed (or pending approval)", "application/json", Schemas.ShiftResponse},
      422 => {"No open shift", "application/json", Schemas.Error}
    }
  )

  def close(conn, _params) do
    with {:ok, shift} <-
           Shifts.close_shift(conn.assigns.current_user, conn.body_params.counted_cash_cents) do
      json(conn, %{data: ApiJSON.shift(shift)})
    end
  end

  operation(:pending,
    summary: "Shifts waiting for approval",
    description: "Managers and above.",
    responses: %{
      200 => {"Shifts", "application/json", Schemas.ShiftsResponse},
      403 => {"Requires manager role", "application/json", Schemas.Error}
    }
  )

  def pending(conn, _params) do
    json(conn, %{data: Enum.map(Shifts.list_pending(), &ApiJSON.shift/1)})
  end

  operation(:approve,
    summary: "Approve a cash difference",
    description: "Managers and above. You cannot approve your own shift.",
    parameters: @id_param,
    request_body: {"Optional note", "application/json", Schemas.ApproveShiftRequest},
    responses: %{
      200 => {"Approved", "application/json", Schemas.ShiftResponse},
      404 => {"Not pending approval", "application/json", Schemas.Error},
      422 => {"Cannot approve your own shift", "application/json", Schemas.Error}
    }
  )

  def approve(conn, %{id: id}) do
    note = Map.get(conn.body_params, :note)

    with {:ok, shift} <- Shifts.approve_shift(conn.assigns.current_user, id, note) do
      json(conn, %{data: ApiJSON.shift(shift)})
    end
  end

  operation(:report,
    summary: "Report for any shift",
    description:
      "Z report for closed shifts (the frozen copy), live X report for open ones. Cashiers see only their own shifts.",
    parameters: @id_param,
    responses: %{
      200 => {"Report", "application/json", Schemas.ShiftReportResponse},
      404 => {"Not found", "application/json", Schemas.Error}
    }
  )

  def report(conn, %{id: id}) do
    user = conn.assigns.current_user

    case Shifts.get_shift(id) do
      nil -> {:error, :not_found}
      %{user_id: owner} when user.role == :cashier and owner != user.id -> {:error, :not_found}
      %{z_report: z} when is_map(z) -> json(conn, %{data: z})
      shift -> json(conn, %{data: blind(Shifts.report(shift), user)})
    end
  end

  # The blind count: a cashier must not see what the drawer should hold before counting it.
  defp blind(report, %{role: :cashier}),
    do: Map.update!(report, :cash, &Map.take(&1, [:opening_float_cents]))

  defp blind(report, _user), do: report
end
