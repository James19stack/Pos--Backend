defmodule Pos.CatalogTest do
  use Pos.DataCase, async: true
  import Pos.Fixtures

  alias Pos.Catalog

  test "finds a product by barcode with its VAT rate loaded" do
    product = product_fixture()
    found = Catalog.get_product_by_barcode(barcode_of(product))

    assert found.id == product.id
    assert found.vat_rate.rate_bp == 1600
  end

  test "trims whitespace around scanned barcodes" do
    product = product_fixture()
    assert Catalog.get_product_by_barcode("  " <> barcode_of(product) <> "\n")
  end

  test "returns nil for unknown barcodes and non-strings" do
    assert Catalog.get_product_by_barcode("0000") == nil
    assert Catalog.get_product_by_barcode(nil) == nil
  end

  test "does not return inactive products" do
    product = product_fixture()

    product
    |> Ecto.Changeset.change(active: false)
    |> Pos.Repo.update!()

    assert Catalog.get_product_by_barcode(barcode_of(product)) == nil
  end

  test "rejects a duplicate barcode and rolls the product back" do
    first = product_fixture()
    vat = Catalog.get_vat_rate_by_code("B")

    assert {:error, changeset} =
             Catalog.create_product(
               %{sku: "OTHER", name: "Other", price_cents: 100, vat_rate_id: vat.id},
               [barcode_of(first)]
             )

    assert %{code: ["has already been taken"]} = errors_on(changeset)
    refute Pos.Repo.get_by(Pos.Catalog.Product, sku: "OTHER")
  end
end
