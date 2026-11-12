defmodule PosWeb.ShiftsApiTest do
  use PosWeb.ConnCase, async: true
  import Pos.Fixtures

  alias PosWeb.Auth.Token

  defp authed(conn, user) do
    {:ok, token, _ttl} = Token.issue(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp post_json(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp sell(conn, user, product) do
    body = %{
      "id" => Ecto.UUID.generate(),
      "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
      "payments" => [%{"method" => "cash", "amount_cents" => product.price_cents}]
    }

    conn |> authed(user) |> post_json("/api/sales", body)
  end

  describe "opening" do
    test "current is null, then open, then a second open is refused", %{conn: conn} do
      user = user_fixture(%{open_shift: false})
      conn = authed(conn, user)

      assert json_response(get(conn, "/api/shifts/current"), 200) == %{"data" => nil}

      opened =
        post_json(conn, "/api/shifts/open", %{
          "opening_float_cents" => 50_000,
          "device_id" => "till-api"
        })

      assert json_response(opened, 201)["data"]["opening_float_cents"] == 50_000

      assert json_response(get(conn, "/api/shifts/current"), 200)["data"]["status"] == "open"

      again = post_json(conn, "/api/shifts/open", %{"opening_float_cents" => 0})
      assert json_response(again, 422)["error"]["code"] == "shift_already_open"
    end

    test "selling without a shift is a 422", %{conn: conn} do
      user = user_fixture(%{open_shift: false})
      resp = sell(conn, user, product_fixture())
      assert json_response(resp, 422)["error"]["code"] == "no_open_shift"
    end
  end

  describe "reports" do
    test "the X report hides expected cash from cashiers but not from supervisors", %{conn: conn} do
      cashier = user_fixture()
      supervisor = user_fixture(%{role: :supervisor})
      sell(conn, cashier, product_fixture(price_cents: 10_000))

      mine = conn |> authed(cashier) |> get("/api/shifts/current/report") |> json_response(200)
      assert mine["data"]["sales_count"] == 1
      assert mine["data"]["cash"] == %{"opening_float_cents" => 0}

      theirs =
        conn |> authed(supervisor) |> get("/api/shifts/current/report") |> json_response(200)

      assert Map.has_key?(theirs["data"]["cash"], "expected_cash_cents")
    end

    test "a cashier cannot read another cashier's shift", %{conn: conn} do
      owner = user_fixture()
      shift = Pos.Shifts.get_open_shift(owner)

      assert json_response(
               conn |> authed(user_fixture()) |> get("/api/shifts/#{shift.id}/report"),
               404
             )

      assert json_response(conn |> authed(owner) |> get("/api/shifts/#{shift.id}/report"), 200)

      assert json_response(
               conn
               |> authed(user_fixture(%{role: :supervisor}))
               |> get("/api/shifts/#{shift.id}/report"),
               200
             )
    end
  end

  describe "cash-up" do
    test "an exact count closes the shift and returns the Z report", %{conn: conn} do
      user = user_fixture()
      sell(conn, user, product_fixture(price_cents: 10_000))

      resp =
        conn |> authed(user) |> post_json("/api/shifts/close", %{"counted_cash_cents" => 10_000})

      shift = json_response(resp, 200)["data"]

      assert shift["status"] == "closed"
      assert shift["expected_cash_cents"] == 10_000
      assert shift["difference_cents"] == 0
      assert shift["z_report"]["sales_count"] == 1
    end

    test "a big difference waits for a manager, who cannot approve their own", %{conn: conn} do
      cashier = user_fixture()
      manager = user_fixture(%{role: :manager})

      resp =
        conn
        |> authed(cashier)
        |> post_json("/api/shifts/close", %{"counted_cash_cents" => 100_000})

      pending = json_response(resp, 200)["data"]
      assert pending["status"] == "pending_approval"

      assert json_response(conn |> authed(cashier) |> get("/api/shifts/pending"), 403)

      [row] = json_response(conn |> authed(manager) |> get("/api/shifts/pending"), 200)["data"]
      assert row["id"] == pending["id"]

      approved =
        conn
        |> authed(manager)
        |> post_json("/api/shifts/#{pending["id"]}/approve", %{"note" => "ok"})

      assert json_response(approved, 200)["data"]["status"] == "closed"

      # a manager's own pending shift
      own =
        conn
        |> authed(manager)
        |> post_json("/api/shifts/close", %{"counted_cash_cents" => 100_000})

      own_id = json_response(own, 200)["data"]["id"]
      resp = conn |> authed(manager) |> post_json("/api/shifts/#{own_id}/approve", %{})
      assert json_response(resp, 422)["error"]["code"] == "cannot_approve_own_shift"
    end

    test "closing with nothing open is a 422", %{conn: conn} do
      user = user_fixture(%{open_shift: false})
      resp = conn |> authed(user) |> post_json("/api/shifts/close", %{"counted_cash_cents" => 0})
      assert json_response(resp, 422)["error"]["code"] == "no_open_shift"
    end
  end
end
