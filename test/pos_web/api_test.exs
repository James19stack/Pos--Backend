defmodule PosWeb.ApiTest do
  use PosWeb.ConnCase, async: true
  import Pos.Fixtures

  alias PosWeb.Auth.Token

  defp authed(conn, user) do
    {:ok, token, _ttl} = Token.issue(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp sale_body(product, extra \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
        "payments" => [%{"method" => "cash", "amount_cents" => product.price_cents}]
      },
      extra
    )
  end

  describe "login" do
    test "returns a token for valid credentials", %{conn: conn} do
      user_fixture(%{email: "login@example.com", password: "password123"})

      conn =
        post_json(conn, "/api/auth/login", %{
          "email" => "login@example.com",
          "password" => "password123"
        })

      body = json_response(conn, 200)["data"]

      assert is_binary(body["token"])
      assert body["user"]["email"] == "login@example.com"
    end

    test "rejects a wrong password", %{conn: conn} do
      user_fixture(%{email: "login@example.com"})

      conn =
        post_json(conn, "/api/auth/login", %{
          "email" => "login@example.com",
          "password" => "nope-nope"
        })

      assert json_response(conn, 401)["error"]["code"] == "invalid_credentials"
    end

    test "rejects a deactivated user", %{conn: conn} do
      user = user_fixture(%{email: "off@example.com"})
      user |> Ecto.Changeset.change(active: false) |> Pos.Repo.update!()

      conn =
        post_json(conn, "/api/auth/login", %{
          "email" => "off@example.com",
          "password" => "password123"
        })

      assert json_response(conn, 401)
    end
  end

  describe "authentication" do
    test "requests without a token are rejected", %{conn: conn} do
      assert json_response(get(conn, "/api/catalog"), 401)["error"]["code"] == "unauthorized"
    end

    test "garbage tokens are rejected", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer not.a.token") |> get("/api/catalog")
      assert json_response(conn, 401)
    end

    test "a deactivated user's existing token stops working", %{conn: conn} do
      user = user_fixture()
      token_conn = authed(conn, user)
      user |> Ecto.Changeset.change(active: false) |> Pos.Repo.update!()

      assert json_response(get(token_conn, "/api/me"), 401)
    end
  end

  describe "catalog" do
    test "lists products with barcodes and VAT", %{conn: conn} do
      product = product_fixture()
      conn = conn |> authed(user_fixture()) |> get("/api/catalog")

      [item] = json_response(conn, 200)["data"]
      assert item["id"] == product.id
      assert item["vat_rate_bp"] == 1600
      assert item["barcodes"] == [barcode_of(product)]
    end

    test "looks up by barcode, 404 when unknown", %{conn: conn} do
      product = product_fixture()
      conn = authed(conn, user_fixture())

      found = get(conn, "/api/products/barcode/#{barcode_of(product)}")
      assert json_response(found, 200)["data"]["id"] == product.id

      missing = get(conn, "/api/products/barcode/0000")
      assert json_response(missing, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/sales" do
    test "creates a sale (201) and a repeat of the same id returns 200", %{conn: conn} do
      product = product_fixture(price_cents: 10_000)
      conn = authed(conn, user_fixture())
      body = sale_body(product)

      first = post_json(conn, "/api/sales", body)

      assert %{"total_cents" => 10_000, "status" => "completed"} =
               json_response(first, 201)["data"]

      second = post_json(conn, "/api/sales", body)
      assert json_response(second, 200)["data"]["id"] == body["id"]
    end

    test "returns change due", %{conn: conn} do
      product = product_fixture(price_cents: 10_000)

      body =
        sale_body(product, %{
          "payments" => [
            %{"method" => "cash", "amount_cents" => 10_000, "tendered_cents" => 12_000}
          ]
        })

      conn = conn |> authed(user_fixture()) |> post_json("/api/sales", body)
      assert json_response(conn, 201)["data"]["change_due_cents"] == 2_000
    end

    test "422 when the body fails schema validation", %{conn: conn} do
      conn =
        conn
        |> authed(user_fixture())
        |> post_json("/api/sales", %{
          "id" => Ecto.UUID.generate(),
          "items" => [],
          "payments" => []
        })

      assert json_response(conn, 422)
    end

    test "422 for an unknown barcode", %{conn: conn} do
      body = %{
        "id" => Ecto.UUID.generate(),
        "items" => [%{"barcode" => "000", "quantity" => 1}],
        "payments" => [%{"method" => "cash", "amount_cents" => 100}]
      }

      conn = conn |> authed(user_fixture()) |> post_json("/api/sales", body)
      assert json_response(conn, 422)["error"]["code"] == "unknown_barcode"
    end

    test "422 when payments do not match the total", %{conn: conn} do
      product = product_fixture(price_cents: 10_000)
      body = sale_body(product, %{"payments" => [%{"method" => "cash", "amount_cents" => 5_000}]})

      conn = conn |> authed(user_fixture()) |> post_json("/api/sales", body)
      resp = json_response(conn, 422)["error"]
      assert resp["code"] == "payment_mismatch"
      assert resp["details"]["expected_cents"] == 10_000
    end
  end

  describe "reading sales" do
    test "a cashier sees their own sale but not another cashier's", %{conn: conn} do
      product = product_fixture()
      owner = user_fixture()
      other = user_fixture()
      body = sale_body(product)
      post_json(authed(conn, owner), "/api/sales", body)

      assert json_response(get(authed(conn, owner), "/api/sales/#{body["id"]}"), 200)
      assert json_response(get(authed(conn, other), "/api/sales/#{body["id"]}"), 404)
    end

    test "a supervisor can see any sale", %{conn: conn} do
      product = product_fixture()
      body = sale_body(product)
      post_json(authed(conn, user_fixture()), "/api/sales", body)

      supervisor = user_fixture(%{role: :supervisor})
      assert json_response(get(authed(conn, supervisor), "/api/sales/#{body["id"]}"), 200)
    end
  end

  describe "roles" do
    test "review list is forbidden for cashiers and open to managers", %{conn: conn} do
      product = product_fixture(stock: 0)
      body = sale_body(product)
      post_json(authed(conn, user_fixture()), "/api/sales", body)

      assert json_response(get(authed(conn, user_fixture()), "/api/sales/review"), 403)["error"][
               "code"
             ] == "forbidden"

      manager = user_fixture(%{role: :manager})
      [flagged] = json_response(get(authed(conn, manager), "/api/sales/review"), 200)["data"]
      assert flagged["id"] == body["id"]
      assert flagged["needs_review"]
    end
  end

  describe "documentation" do
    test "serves the OpenAPI spec with the documented paths", %{conn: conn} do
      spec = json_response(get(conn, "/api/openapi"), 200)

      assert spec["info"]["title"] == "Supermarket POS API"
      assert Map.has_key?(spec["paths"], "/api/sales")
      assert Map.has_key?(spec["paths"], "/api/auth/login")
    end

    test "serves Swagger UI", %{conn: conn} do
      assert html_response(get(conn, "/api/swagger"), 200) =~ "swagger"
    end
  end
end
