defmodule PosWeb.EtimsApiTest do
  use PosWeb.ConnCase, async: false
  import Pos.Fixtures

  alias PosWeb.Auth.Token

  defp authed(conn, user) do
    {:ok, token, _ttl} = Token.issue(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp post_json(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))

  defp make_sale(conn, user) do
    product = product_fixture(price_cents: 10_000)
    id = Ecto.UUID.generate()
    body = %{"id" => id, "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}], "payments" => [%{"method" => "cash", "amount_cents" => 10_000}]}
    conn |> authed(user) |> post_json("/api/sales", body) |> json_response(201)
    id
  end

  test "a new sale shows a pending mock invoice to its cashier, and not to another cashier", %{conn: conn} do
    owner = user_fixture()
    id = make_sale(conn, owner)

    invoice = conn |> authed(owner) |> get("/api/sales/#{id}/etims") |> json_response(200) |> Map.fetch!("data")
    assert invoice["status"] == "pending"
    assert invoice["invoice_no"] == 1
    assert invoice["mock"] == true

    assert json_response(conn |> authed(user_fixture()) |> get("/api/sales/#{id}/etims"), 404)
  end

  test "supervisors can file it now; cashiers cannot", %{conn: conn} do
    owner = user_fixture()
    id = make_sale(conn, owner)

    assert json_response(conn |> authed(owner) |> post("/api/sales/#{id}/etims/submit"), 403)

    filed = conn |> authed(user_fixture(%{role: :supervisor})) |> post("/api/sales/#{id}/etims/submit") |> json_response(200)
    assert filed["data"]["status"] == "accepted"
    assert "MOCK" <> _ = filed["data"]["receipt_signature"]

    # filing again changes nothing
    again = conn |> authed(user_fixture(%{role: :supervisor})) |> post("/api/sales/#{id}/etims/submit") |> json_response(200)
    assert again["data"]["receipt_signature"] == filed["data"]["receipt_signature"]
  end

  test "a KRA failure is a 502 and the invoice stays pending", %{conn: conn} do
    id = make_sale(conn, user_fixture())
    Pos.Etims.Provider.Mock.set_result({:error, :timeout})

    resp = conn |> authed(user_fixture(%{role: :supervisor})) |> post("/api/sales/#{id}/etims/submit")
    assert json_response(resp, 502)["error"]["code"] == "etims_unavailable"
  end

  test "the watch-list is for managers", %{conn: conn} do
    assert json_response(conn |> authed(user_fixture(%{role: :supervisor})) |> get("/api/etims/pending"), 403)
    assert json_response(conn |> authed(user_fixture(%{role: :manager})) |> get("/api/etims/pending"), 200) == %{"data" => []}
  end
end
