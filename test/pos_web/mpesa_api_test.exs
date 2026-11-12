defmodule PosWeb.MpesaApiTest do
  use PosWeb.ConnCase, async: true
  import Ecto.Query
  import Pos.Fixtures

  alias Pos.Payments.{FakeDaraja, Mpesa, MpesaRequest}
  alias PosWeb.Auth.Token

  defp authed(conn, user) do
    {:ok, token, _ttl} = Token.issue(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp post_json(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp stk_body(opts \\ []) do
    %{
      "sale_id" => Keyword.get(opts, :sale_id, Ecto.UUID.generate()),
      "phone" => Keyword.get(opts, :phone, "0712345678"),
      "amount_cents" => Keyword.get(opts, :amount_cents, 10_000)
    }
  end

  defp callback_secret, do: Application.fetch_env!(:pos, :daraja)[:callback_secret]

  describe "POST /api/mpesa/stk" do
    test "requires a token", %{conn: conn} do
      assert json_response(post_json(conn, "/api/mpesa/stk", stk_body()), 401)
    end

    test "sends a prompt (201), and repeating it returns the same request (200)", %{conn: conn} do
      conn = authed(conn, user_fixture())
      body = stk_body()

      first = json_response(post_json(conn, "/api/mpesa/stk", body), 201)["data"]
      assert first["status"] == "pending"
      assert first["phone"] == "254712345678"
      assert_received {:stk_push, %{amount: 100}}

      second = json_response(post_json(conn, "/api/mpesa/stk", body), 200)["data"]
      assert second["id"] == first["id"]
      refute_received {:stk_push, _}
    end

    test "rejects amounts with cents and bad phone numbers", %{conn: conn} do
      conn = authed(conn, user_fixture())

      resp = post_json(conn, "/api/mpesa/stk", stk_body(amount_cents: 10_050))
      assert json_response(resp, 422)["error"]["code"] == "amount_must_be_whole_shillings"

      resp = post_json(conn, "/api/mpesa/stk", stk_body(phone: "12345"))
      assert json_response(resp, 422)["error"]["code"] == "invalid_phone"
    end

    test "returns 502 when M-Pesa cannot be reached", %{conn: conn} do
      FakeDaraja.set_push({:error, :timeout})
      resp = conn |> authed(user_fixture()) |> post_json("/api/mpesa/stk", stk_body())
      assert json_response(resp, 502)["error"]["code"] == "mpesa_unavailable"
    end
  end

  describe "reading and checking requests" do
    test "owner and supervisors can read a request, other cashiers cannot", %{conn: conn} do
      owner = user_fixture()

      {:ok, request, _} =
        Mpesa.initiate(owner, %{
          sale_id: Ecto.UUID.generate(),
          phone: "0712345678",
          amount_cents: 10_000
        })

      path = "/api/mpesa/requests/#{request.id}"

      assert json_response(get(authed(conn, owner), path), 200)["data"]["id"] == request.id
      assert json_response(get(authed(conn, user_fixture(%{role: :supervisor})), path), 200)
      assert json_response(get(authed(conn, user_fixture()), path), 404)
    end

    test "check asks Daraja and updates the request", %{conn: conn} do
      owner = user_fixture()

      {:ok, request, _} =
        Mpesa.initiate(owner, %{
          sale_id: Ecto.UUID.generate(),
          phone: "0712345678",
          amount_cents: 10_000
        })

      FakeDaraja.set_query({:ok, %{result_code: 0, result_desc: "ok"}})

      resp = conn |> authed(owner) |> post("/api/mpesa/requests/#{request.id}/check")
      assert json_response(resp, 200)["data"]["status"] == "confirmed"
    end

    test "unclaimed payments are for managers only", %{conn: conn} do
      user = user_fixture()
      paid = confirmed_mpesa_request(user, Ecto.UUID.generate(), 10_000)
      ago = DateTime.add(DateTime.utc_now(), -600, :second)

      Pos.Repo.update_all(from(r in MpesaRequest, where: r.id == ^paid.id),
        set: [inserted_at: ago]
      )

      assert json_response(get(authed(conn, user), "/api/mpesa/unclaimed"), 403)

      [row] =
        json_response(
          get(authed(conn, user_fixture(%{role: :manager})), "/api/mpesa/unclaimed"),
          200
        )["data"]

      assert row["id"] == paid.id
      refute row["claimed"]
    end
  end

  describe "Safaricom callback" do
    test "the wrong secret gets a 404 and changes nothing", %{conn: conn} do
      {:ok, request, _} =
        Mpesa.initiate(user_fixture(), %{
          sale_id: Ecto.UUID.generate(),
          phone: "0712345678",
          amount_cents: 10_000
        })

      resp = post_json(conn, "/api/callbacks/daraja/wrong-secret", mpesa_callback(request))
      assert response(resp, 404)
      assert Pos.Repo.get!(MpesaRequest, request.id).status == :pending
    end

    test "the right secret confirms the payment and is acknowledged", %{conn: conn} do
      {:ok, request, _} =
        Mpesa.initiate(user_fixture(), %{
          sale_id: Ecto.UUID.generate(),
          phone: "0712345678",
          amount_cents: 10_000
        })

      resp =
        post_json(conn, "/api/callbacks/daraja/#{callback_secret()}", mpesa_callback(request))

      assert json_response(resp, 200) == %{"ResultCode" => 0, "ResultDesc" => "Accepted"}
      assert Pos.Repo.get!(MpesaRequest, request.id).status == :confirmed
    end

    test "garbage is acknowledged without crashing", %{conn: conn} do
      resp = post_json(conn, "/api/callbacks/daraja/#{callback_secret()}", %{"hello" => "world"})
      assert json_response(resp, 200)["ResultCode"] == 0
    end
  end

  test "full flow: prompt, callback, then the sale is recorded with M-Pesa", %{conn: conn} do
    user = user_fixture()
    product = product_fixture(price_cents: 20_000)
    sale_id = Ecto.UUID.generate()

    request =
      conn
      |> authed(user)
      |> post_json("/api/mpesa/stk", stk_body(sale_id: sale_id, amount_cents: 20_000))
      |> json_response(201)
      |> Map.fetch!("data")

    db_request = Pos.Repo.get!(MpesaRequest, request["id"])

    post_json(
      conn,
      "/api/callbacks/daraja/#{callback_secret()}",
      mpesa_callback(db_request, 0, receipt: "NLJ7RT61SV")
    )

    sale = %{
      "id" => sale_id,
      "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
      "payments" => [
        %{"method" => "mpesa", "amount_cents" => 20_000, "mpesa_request_id" => request["id"]}
      ]
    }

    resp = conn |> authed(user) |> post_json("/api/sales", sale)
    [payment] = json_response(resp, 201)["data"]["payments"]
    assert payment["method"] == "mpesa"
    assert payment["reference"] == "NLJ7RT61SV"

    shown = conn |> authed(user) |> get("/api/mpesa/requests/#{request["id"]}")
    assert json_response(shown, 200)["data"]["claimed"]
  end

  describe "payments made straight to the till" do
    test "the confirmation endpoint stores a payment, and the wrong secret gets a 404", %{
      conn: conn
    } do
      payload = c2b_payload(trans_id: "RKAPI00001")

      assert response(
               post_json(conn, "/api/callbacks/daraja/wrong/c2b/confirmation", payload),
               404
             )

      refute Pos.Payments.C2B.get_by_code("RKAPI00001")

      resp =
        post_json(conn, "/api/callbacks/daraja/#{callback_secret()}/c2b/confirmation", payload)

      assert json_response(resp, 200)["ResultCode"] == 0
      assert Pos.Payments.C2B.get_by_code("RKAPI00001")
    end

    test "validation always accepts", %{conn: conn} do
      resp =
        post_json(
          conn,
          "/api/callbacks/daraja/#{callback_secret()}/c2b/validation",
          c2b_payload()
        )

      assert json_response(resp, 200)["ResultCode"] == "0"
    end

    test "full flow: notification, lookup by code, then the sale", %{conn: conn} do
      user = user_fixture()
      product = product_fixture(price_cents: 20_000)

      post_json(
        conn,
        "/api/callbacks/daraja/#{callback_secret()}/c2b/confirmation",
        c2b_payload(trans_id: "RKFLOW0001", amount: "200.00")
      )

      found = conn |> authed(user) |> get("/api/mpesa/payments/rkflow0001") |> json_response(200)
      assert found["data"]["amount_cents"] == 20_000
      assert found["data"]["payer_name"] == "John Doe"
      refute found["data"]["claimed"]

      sale = %{
        "id" => Ecto.UUID.generate(),
        "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
        "payments" => [
          %{"method" => "mpesa", "amount_cents" => 20_000, "mpesa_trans_id" => "RKFLOW0001"}
        ]
      }

      resp = conn |> authed(user) |> post_json("/api/sales", sale)

      assert json_response(resp, 201)["data"]["payments"] |> hd() |> Map.get("reference") ==
               "RKFLOW0001"

      again = conn |> authed(user) |> get("/api/mpesa/payments/RKFLOW0001") |> json_response(200)
      assert again["data"]["claimed"]
    end

    test "an unknown code is a 404 and needs a token", %{conn: conn} do
      assert json_response(get(conn, "/api/mpesa/payments/ABC"), 401)
      assert json_response(conn |> authed(user_fixture()) |> get("/api/mpesa/payments/ABC"), 404)
    end
  end
end
