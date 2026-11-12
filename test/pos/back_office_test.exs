defmodule Pos.BackOfficeTest do
  use Pos.DataCase, async: true
  import Pos.Fixtures

  alias Pos.{Audit, Catalog, Inventory, Repo}
  alias Pos.Catalog.{Import, Product}

  setup do
    vat_rate_fixture()
    vat_rate_fixture(%{code: "A", name: "Exempt", rate_bp: 0})
    %{manager: user_fixture(%{role: :manager})}
  end

  @csv """
  sku,name,barcode,price,cost,vat_code,weighed,unit,reorder_level,opening_stock
  M001,Maize Flour 2kg,6161100000001|6161100000002,190.00,150,B,,,20,100
  T001,Tomatoes (per kg),2000001,120,,A,yes,kg,10,50.5
  """

  defp by_sku(sku), do: Product |> Repo.get_by!(sku: sku) |> Repo.preload([:barcodes, :stock_level, :vat_rate])

  describe "CSV import" do
    test "creates products with barcodes, prices in cents, flags and opening stock", %{manager: manager} do
      assert {:ok, %{created: 2, updated: 0, dry_run: false}} = Import.run(manager, @csv)

      maize = by_sku("M001")
      assert maize.price_cents == 19_000
      assert maize.cost_cents == 15_000
      assert maize.vat_rate.code == "B"
      assert Enum.sort(Enum.map(maize.barcodes, & &1.code)) == ["6161100000001", "6161100000002"]
      assert Decimal.eq?(maize.reorder_level, 20)
      assert Decimal.eq?(Inventory.stock_on_hand(maize.id), 100)

      tomatoes = by_sku("T001")
      assert tomatoes.is_weighed
      assert tomatoes.unit == "kg"
      assert Decimal.eq?(Inventory.stock_on_hand(tomatoes.id), Decimal.new("50.5"))
    end

    test "a dry run reports counts and saves nothing", %{manager: manager} do
      assert {:ok, %{created: 2, dry_run: true}} = Import.run(manager, @csv, dry_run: true)
      assert Repo.aggregate(Product, :count) == 0
    end

    test "re-importing updates prices (audited), adds new barcodes, and leaves stock alone", %{manager: manager} do
      {:ok, _} = Import.run(manager, @csv)

      updated_csv = """
      sku,name,barcode,price,vat_code,opening_stock
      M001,Maize Flour 2kg,6161100000003,"1,250.50",B,9999
      """

      assert {:ok, %{created: 0, updated: 1}} = Import.run(manager, updated_csv)

      maize = by_sku("M001")
      assert maize.price_cents == 125_050
      assert length(maize.barcodes) == 3
      assert Decimal.eq?(Inventory.stock_on_hand(maize.id), 100)

      assert %{changes: %{"price_cents" => %{"from" => 19_000, "to" => 125_050}}} =
               maize.id |> then(&Audit.for_entity("product", &1)) |> Enum.find(&(&1.action == "product.updated"))
    end

    test "any bad row means nothing is saved, and every problem has its row number", %{manager: manager} do
      bad = """
      sku,name,barcode,price,vat_code
      OK1,Fine,111,10,B
      BAD1,No price,222,,B
      BAD2,Wrong VAT,333,10,Z
      BAD3,Dup barcode,111,10,B
      BAD4,Not a number,444,abc,B
      """

      assert {:error, %{errors: errors}} = Import.run(manager, bad)
      assert Enum.map(errors, & &1.row) == [3, 4, 5, 6]
      assert Enum.any?(errors, &(&1.error =~ "price is empty"))
      assert Enum.any?(errors, &(&1.error =~ "Unknown vat_code"))
      assert Enum.any?(errors, &(&1.error =~ "appears twice"))
      assert Repo.aggregate(Product, :count) == 0
    end

    test "a barcode that belongs to another product is refused", %{manager: manager} do
      existing = product_fixture()
      csv = "sku,name,barcode,price,vat_code\nNEW1,New,#{barcode_of(existing)},10,B\n"

      assert {:error, %{errors: [%{row: 2, error: error}]}} = Import.run(manager, csv)
      assert error =~ "already belongs to another product"
    end

    test "rejects files with missing columns, no rows, or a BOM-prefixed header is still fine", %{manager: manager} do
      assert {:error, %{errors: [%{error: "Missing column(s): price"}]}} = Import.run(manager, "sku,name,vat_code\nA,B,B\n")
      assert {:error, %{errors: [%{error: "The file has no products"}]}} = Import.run(manager, "sku,name,price,vat_code\n")
      assert {:ok, %{created: 1}} = Import.run(manager, "\uFEFFsku,name,price,vat_code\nB1,Bread,65,B\n")
    end
  end

  describe "updating products" do
    test "price and cost changes are audited with old and new values; no-op changes are not", %{manager: manager} do
      product = product_fixture(price_cents: 10_000)
      product = Catalog.get_product(product.id)

      assert {:ok, _} = Catalog.update_product(manager, product, %{price_cents: 12_000})
      assert {:ok, _} = Catalog.update_product(manager, product, %{name: product.name})

      [log] = Audit.for_entity("product", product.id) |> Enum.filter(&(&1.action == "product.updated"))
      assert log.user_id == manager.id
      assert log.changes["price_cents"] == %{"from" => 10_000, "to" => 12_000}
    end

    test "rejects invalid changes and leaves the product alone", %{manager: manager} do
      product = Catalog.get_product(product_fixture(price_cents: 10_000).id)
      assert {:error, %Ecto.Changeset{}} = Catalog.update_product(manager, product, %{price_cents: -5})
      assert Catalog.get_product(product.id).price_cents == 10_000
    end
  end

  describe "searching" do
    test "by name, sku or exact barcode" do
      a = product_fixture(name: "Brookside Milk 500ml")
      _b = product_fixture(name: "Sugar 1kg")

      assert [%{id: id}] = Catalog.list_products(q: "brook")
      assert id == a.id
      assert [%{id: ^id}] = Catalog.list_products(q: a.sku)
      assert [%{id: ^id}] = Catalog.list_products(q: barcode_of(a))
      assert length(Catalog.list_products()) == 2
      assert Catalog.list_products(q: "100%") == []
    end
  end

  describe "adjustments" do
    test "wastage and expiry always remove stock, whatever the sign", %{manager: manager} do
      product = product_fixture(stock: 50)

      assert {:ok, _} = Inventory.record_adjustment(manager, product.id, 5, :wastage, "Dropped crate")
      assert {:ok, _} = Inventory.record_adjustment(manager, product.id, -3, :expiry, "Past date")
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 42)
    end

    test "a general adjustment is signed", %{manager: manager} do
      product = product_fixture(stock: 10)
      assert {:ok, _} = Inventory.record_adjustment(manager, product.id, 4, :adjustment, "Found in store room")
      assert {:ok, _} = Inventory.record_adjustment(manager, product.id, -1, :adjustment, "Miscount")
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 13)
    end

    test "needs a note, a real quantity and is audited", %{manager: manager} do
      product = product_fixture(stock: 10)

      assert {:error, :note_required} = Inventory.record_adjustment(manager, product.id, 1, :wastage, "  ")
      assert {:error, :invalid_quantity} = Inventory.record_adjustment(manager, product.id, "lots", :wastage, "x")
      assert {:error, %Ecto.Changeset{}} = Inventory.record_adjustment(manager, product.id, 0, :adjustment, "nothing")
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 10)

      {:ok, _} = Inventory.record_adjustment(manager, product.id, 2, :wastage, "Spilt")
      assert [%{action: "stock.wastage", changes: %{"note" => "Spilt", "quantity" => "-2"}}] = Audit.for_entity("product", product.id)
    end
  end

  describe "receiving goods" do
    test "adds stock, updates the cost (audited) and keeps a receipt", %{manager: manager} do
      product = product_fixture(stock: 10, price_cents: 20_000)
      id = Ecto.UUID.generate()

      attrs = %{
        id: id,
        supplier_name: "Brookside",
        reference: "DN-1001",
        items: [%{barcode: barcode_of(product), quantity: 24, unit_cost_cents: 14_500}]
      }

      assert {:ok, receipt} = Inventory.receive_goods(manager, attrs)
      assert receipt.supplier_name == "Brookside"
      assert [%{unit_cost_cents: 14_500}] = receipt.items
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 34)
      assert Catalog.get_product(product.id).cost_cents == 14_500
      assert Enum.any?(Audit.for_entity("product", product.id), &(&1.action == "product.updated"))
    end

    test "posting the same receipt twice never adds the stock twice", %{manager: manager} do
      product = product_fixture(stock: 0)
      attrs = %{id: Ecto.UUID.generate(), items: [%{sku: product.sku, quantity: 12}]}

      assert {:ok, first} = Inventory.receive_goods(manager, attrs)
      assert {:ok, second} = Inventory.receive_goods(manager, attrs)
      assert first.id == second.id
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 12)
    end

    test "an unknown product or a bad quantity saves nothing", %{manager: manager} do
      product = product_fixture(stock: 5)

      assert {:error, {:unknown_barcode, "000"}} =
               Inventory.receive_goods(manager, %{id: Ecto.UUID.generate(), items: [%{barcode: barcode_of(product), quantity: 5}, %{barcode: "000", quantity: 1}]})

      assert {:error, :invalid_quantity} =
               Inventory.receive_goods(manager, %{id: Ecto.UUID.generate(), items: [%{barcode: barcode_of(product), quantity: 0}]})

      assert {:error, :no_items} = Inventory.receive_goods(manager, %{id: Ecto.UUID.generate(), items: []})
      assert Decimal.eq?(Inventory.stock_on_hand(product.id), 5)
    end
  end

  describe "low stock" do
    test "lists active products at or below the reorder level, including never-stocked ones" do
      low = product_fixture(stock: 3)
      never = product_fixture(stock: 0)
      plenty = product_fixture(stock: 500)

      for p <- [low, never, plenty], do: Repo.update!(Ecto.Changeset.change(Repo.get!(Product, p.id), reorder_level: Decimal.new(10)))

      ids = Enum.map(Inventory.low_stock(), fn {product, _qty} -> product.id end)
      assert low.id in ids
      assert never.id in ids
      refute plenty.id in ids
    end
  end
end
