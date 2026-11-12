defmodule PosWeb.CategoriesApiTest do
  use PosWeb.ConnCase, async: true
  import Pos.Fixtures

  alias PosWeb.Auth.Token

  setup do
    vat_rate_fixture()
    :ok
  end

  defp authed(conn, user) do
    {:ok, token, _ttl} = Token.issue(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp send_json(conn, method, path, body) do
    conn |> put_req_header("content-type", "application/json") |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  test "managers create and change categories; supervisors only read; cashiers see nothing", %{conn: conn} do
    manager = conn |> authed(user_fixture(%{role: :manager}))
    supervisor = conn |> authed(user_fixture(%{role: :supervisor}))
    cashier = conn |> authed(user_fixture())

    created = manager |> send_json(:post, "/api/categories", %{"name" => "Dairy", "etims_item_cls_cd" => "1111111111"}) |> json_response(201)
    id = created["data"]["id"]
    assert created["data"]["etims_item_cls_cd"] == "1111111111"

    assert json_response(send_json(supervisor, :post, "/api/categories", %{"name" => "Nope"}), 403)
    assert [%{"name" => "Dairy"}] = supervisor |> get("/api/categories") |> json_response(200) |> Map.fetch!("data")
    assert json_response(get(cashier, "/api/categories"), 403)

    updated = manager |> send_json(:patch, "/api/categories/#{id}", %{"pkg_unit_cd" => "PK"}) |> json_response(200)
    assert updated["data"]["pkg_unit_cd"] == "PK"
    assert json_response(send_json(manager, :patch, "/api/categories/#{Ecto.UUID.generate()}", %{"name" => "x"}), 404)
  end

  test "a duplicate name is a validation error", %{conn: conn} do
    manager = conn |> authed(user_fixture(%{role: :manager}))
    send_json(manager, :post, "/api/categories", %{"name" => "Dairy"})
    resp = send_json(manager, :post, "/api/categories", %{"name" => "dairy"})
    assert json_response(resp, 422)["error"]["code"] == "validation_failed"
  end

  test "a product created with a category shows its name", %{conn: conn} do
    manager = conn |> authed(user_fixture(%{role: :manager}))
    cat = manager |> send_json(:post, "/api/categories", %{"name" => "Bakery"}) |> json_response(201)

    product = %{"sku" => "CAT-1", "name" => "Bread", "price_cents" => 6_500, "vat_code" => "B", "category_id" => cat["data"]["id"], "barcodes" => ["7771"]}
    created = manager |> send_json(:post, "/api/products", product) |> json_response(201)

    assert created["data"]["category"] == "Bakery"
    assert created["data"]["category_id"] == cat["data"]["id"]
  end
end
