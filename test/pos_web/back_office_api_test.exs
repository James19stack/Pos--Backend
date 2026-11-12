defmodule PosWeb.BackOfficeApiTest do
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

  defp post_json(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  defp patch_json(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> patch(path, Jason.encode!(body))

  defp new_product(overrides \\ %{}) do
    Map.merge(%{"sku" => "API-#{System.unique_integer([:positive])}", "name" => "API product", "price_cents" => 10_000, "vat_code" => "B", "barcodes" => ["999#{System.unique_integer([:positive])}"]}, overrides)
  end

  describe "products" do
    test "cashiers cannot list, supervisors can, supervisors cannot create", %{conn: conn} do
      assert json_response(conn |> authed(user_fixture()) |> get("/api/products"), 403)
      assert json_response(conn |> authed(user_fixture(%{role: :supervisor})) |> get("/api/products"), 200)
      assert json_response(conn |> authed(user_fixture(%{role: :supervisor})) |> post_json("/api/products", new_product()), 403)
    end

    test "a manager creates, finds, changes and retires a product", %{conn: conn} do
      manager = conn |> authed(user_fixture(%{role: :manager}))
      body = new_product(%{"name" => "Zebra Biscuits"})

      created = manager |> post_json("/api/products", body) |> json_response(201)
      assert created["data"]["price_cents"] == 10_000
      assert created["data"]["vat_code"] == "B"
      id = created["data"]["id"]

      [found] = manager |> get("/api/products?q=zebra") |> json_response(200) |> Map.fetch!("data")
      assert found["id"] == id

      updated = manager |> patch_json("/api/products/#{id}", %{"price_cents" => 12_500}) |> json_response(200)
      assert updated["data"]["price_cents"] == 12_500

      retired = manager |> patch_json("/api/products/#{id}", %{"active" => false}) |> json_response(200)
      refute retired["data"]["active"]
    end

    test "unknown VAT code, duplicate sku and unknown id are clear errors", %{conn: conn} do
      manager = conn |> authed(user_fixture(%{role: :manager}))
      body = new_product()

      assert manager |> post_json("/api/products", Map.put(body, "vat_code", "Z")) |> json_response(422) |> get_in(["error", "code"]) == "unknown_vat_code"
      assert json_response(post_json(manager, "/api/products", body), 201)
      assert manager |> post_json("/api/products", Map.put(new_product(), "sku", body["sku"])) |> json_response(422) |> get_in(["error", "code"]) == "validation_failed"
      assert json_response(patch_json(manager, "/api/products/#{Ecto.UUID.generate()}", %{"name" => "x"}), 404)
    end

    test "stock history shows every movement", %{conn: conn} do
      product = product_fixture(stock: 7)
      resp = conn |> authed(user_fixture(%{role: :supervisor})) |> get("/api/products/#{product.id}/movements") |> json_response(200)
      assert [%{"reason" => "opening", "quantity" => "7"}] = resp["data"]
    end
  end

  describe "CSV import" do
    test "a manager imports a file; a bad file lists problems and saves nothing", %{conn: conn} do
      manager = conn |> authed(user_fixture(%{role: :manager}))
      good = "sku,name,barcode,price,vat_code,opening_stock\nCSV1,Bread,5551,65,B,40\n"

      assert manager |> post_json("/api/products/import", %{"csv" => good, "dry_run" => true}) |> json_response(200) |> get_in(["data", "dry_run"])
      assert json_response(post_json(manager, "/api/products/import", %{"csv" => good}), 200)["data"]["created"] == 1

      bad = "sku,name,price,vat_code\nX1,No VAT,10,Q\n"
      resp = manager |> post_json("/api/products/import", %{"csv" => bad}) |> json_response(422)
      assert resp["error"]["code"] == "import_failed"
      assert [%{"row" => 2}] = resp["error"]["details"]["errors"]
    end

    test "supervisors cannot import", %{conn: conn} do
      resp = conn |> authed(user_fixture(%{role: :supervisor})) |> post_json("/api/products/import", %{"csv" => "x"})
      assert json_response(resp, 403)
    end
  end

  describe "stock" do
    test "a delivery adds stock (201), and posting it again is a 200 that adds nothing", %{conn: conn} do
      product = product_fixture(stock: 0)
      supervisor = conn |> authed(user_fixture(%{role: :supervisor}))
      body = %{"id" => Ecto.UUID.generate(), "reference" => "DN-7", "items" => [%{"barcode" => barcode_of(product), "quantity" => 24, "unit_cost_cents" => 7_000}]}

      assert json_response(post_json(supervisor, "/api/stock/receipts", body), 201)["data"]["reference"] == "DN-7"
      assert json_response(post_json(supervisor, "/api/stock/receipts", body), 200)
      assert Decimal.eq?(Pos.Inventory.stock_on_hand(product.id), 24)
    end

    test "supervisors record wastage but not general adjustments; managers can do both", %{conn: conn} do
      product = product_fixture(stock: 20)
      supervisor = conn |> authed(user_fixture(%{role: :supervisor}))
      manager = conn |> authed(user_fixture(%{role: :manager}))
      wastage = %{"barcode" => barcode_of(product), "quantity" => 2, "reason" => "wastage", "note" => "Damaged"}
      adjustment = %{"barcode" => barcode_of(product), "quantity" => 5, "reason" => "adjustment", "note" => "Found"}

      assert json_response(post_json(supervisor, "/api/stock/adjustments", wastage), 201)["data"]["stock_quantity"] == "18"
      assert json_response(post_json(supervisor, "/api/stock/adjustments", adjustment), 403)
      assert json_response(post_json(manager, "/api/stock/adjustments", adjustment), 201)["data"]["stock_quantity"] == "23"
    end

    test "cashiers have no access, and the low-stock list works", %{conn: conn} do
      product = product_fixture(stock: 1)
      Pos.Repo.update!(Ecto.Changeset.change(Pos.Repo.get!(Pos.Catalog.Product, product.id), reorder_level: Decimal.new(5)))

      assert json_response(conn |> authed(user_fixture()) |> get("/api/stock/low"), 403)
      rows = conn |> authed(user_fixture(%{role: :supervisor})) |> get("/api/stock/low") |> json_response(200) |> Map.fetch!("data")
      assert Enum.any?(rows, &(&1["product"]["id"] == product.id and &1["quantity"] == "1"))
    end
  end
end
