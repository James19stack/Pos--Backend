defmodule Pos.CategoriesTest do
  # Not async: eTIMS invoice and item numbers come from shared counters
  use Pos.DataCase, async: false
  import Pos.Fixtures

  alias Pos.{Audit, Catalog, Etims, Repo, Sales}
  alias Pos.Etims.{Codes, Payload}

  setup do
    Application.put_env(:pos, :etims_enabled, true)
    on_exit(fn -> :ok end)
    vat_rate_fixture()
    %{manager: user_fixture(%{role: :manager})}
  end

  defp category!(manager, attrs \\ %{}) do
    {:ok, c} = Catalog.create_category(manager, Map.merge(%{name: "Dairy", etims_item_cls_cd: "1111111111", pkg_unit_cd: "PK", qty_unit_cd: "KG"}, attrs))
    c
  end

  defp in_category(manager, product, category) do
    {:ok, updated} = Catalog.update_product(manager, Catalog.get_product(product.id), %{category_id: category.id})
    updated
  end

  defp sell(user, product) do
    params = %{
      "id" => Ecto.UUID.generate(),
      "items" => [%{"barcode" => barcode_of(product), "quantity" => 1}],
      "payments" => [%{"method" => "cash", "amount_cents" => product.price_cents}]
    }

    {:ok, sale} = Sales.create_sale(params, user)
    sale
  end

  describe "categories" do
    test "are created and changed with an audit trail", %{manager: manager} do
      category = category!(manager)
      assert [%{action: "category.created"}] = Audit.for_entity("category", category.id)

      {:ok, _} = Catalog.update_category(manager, category, %{etims_item_cls_cd: "2222222222"})
      [_, log] = Audit.for_entity("category", category.id)
      assert log.changes["etims_item_cls_cd"] == %{"from" => "1111111111", "to" => "2222222222"}
    end

    test "names are unique regardless of case", %{manager: manager} do
      category!(manager, %{name: "Dairy"})
      assert {:error, %Ecto.Changeset{} = cs} = Catalog.create_category(manager, %{name: "  DAIRY "})
      assert %{name: ["already exists"]} = errors_on(cs)
    end

    test "a name is required", %{manager: manager} do
      assert {:error, %Ecto.Changeset{}} = Catalog.create_category(manager, %{name: ""})
    end

    test "a product can be moved into one, and the change is audited", %{manager: manager} do
      product = product_fixture()
      category = category!(manager)
      updated = in_category(manager, product, category)

      assert updated.category.name == "Dairy"
      assert Enum.any?(Audit.for_entity("product", product.id), &(&1.changes["category_id"]))
    end
  end

  describe "which KRA codes apply" do
    test "the product's own code wins, then its category's, then the placeholder default", %{manager: manager} do
      category = category!(manager)
      plain = Catalog.get_product(product_fixture().id)
      defaults = %{item_cls_cd: "9999999999", pkg_unit_cd: "ZZ", qty_unit_cd: "Z"}

      assert %{item_cls_cd: "9999999999", pkg_unit_cd: "ZZ"} = Codes.resolve(plain, defaults)

      in_cat = in_category(manager, plain, category)
      assert %{item_cls_cd: "1111111111", pkg_unit_cd: "PK", qty_unit_cd: "KG"} = Codes.resolve(in_cat, defaults)

      {:ok, own} = Catalog.update_product(manager, in_cat, %{etims_item_cls_cd: "3333333333"})
      assert %{item_cls_cd: "3333333333", pkg_unit_cd: "PK"} = Codes.resolve(own, defaults)
    end

    test "registration and the invoice line use the category's codes", %{manager: manager} do
      cashier = user_fixture()
      product = product_fixture()
      in_category(manager, product, category!(manager))
      sale = sell(cashier, product)

      {:ok, _} = Etims.submit(Etims.get_invoice_for_sale(sale.id).id)
      assert_received {:etims_save_item, item}
      assert item["itemClsCd"] == "1111111111"
      assert item["pkgUnitCd"] == "PK"
      assert item["itemCd"] =~ ~r/^KE2PKKG\d{7}$/

      [line] = Payload.build(Etims.load_sale(sale.id), 1, Etims.config())["itemList"]
      assert line["itemClsCd"] == "1111111111"
      assert line["qtyUnitCd"] == "KG"
    end
  end

  describe "CSV import with a category column" do
    test "assigns the category, matching names without caring about case", %{manager: manager} do
      category!(manager, %{name: "Fresh Produce"})
      csv = "sku,name,price,vat_code,category\nTOM1,Tomatoes,120,B,fresh produce\nBRD1,Bread,65,B,\n"

      assert {:ok, %{created: 2}} = Catalog.Import.run(manager, csv)
      assert Repo.get_by!(Catalog.Product, sku: "TOM1") |> Repo.preload(:category) |> Map.get(:category) |> Map.get(:name) == "Fresh Produce"
      assert Repo.get_by!(Catalog.Product, sku: "BRD1").category_id == nil
    end

    test "an unknown category is an error with its row number, and nothing is saved", %{manager: manager} do
      category!(manager)
      csv = "sku,name,price,vat_code,category\nA1,Milk,65,B,Dairy\nA2,Bread,65,B,Bakery\n"

      assert {:error, %{errors: [%{row: 3, error: error}]}} = Catalog.Import.run(manager, csv)
      assert error =~ "Unknown category"
      assert error =~ "Dairy"
      assert Repo.aggregate(Catalog.Product, :count) == 0
    end
  end
end
