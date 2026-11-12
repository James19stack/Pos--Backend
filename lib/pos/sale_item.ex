defmodule Pos.Sales.SaleItem do
  use Pos.Schema

  alias Pos.Catalog.Product
  alias Pos.Sales.Sale

  schema "sale_items" do
    # Snapshots: later edits to the product never change past sales
    field :product_name, :string
    field :barcode, :string
    field :quantity, :decimal
    field :unit_price_cents, :integer
    field :vat_rate_bp, :integer
    field :vat_code, :string
    field :line_total_cents, :integer
    field :line_vat_cents, :integer

    belongs_to :sale, Sale
    belongs_to :product, Product

    timestamps(updated_at: false)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :product_id,
      :product_name,
      :barcode,
      :quantity,
      :unit_price_cents,
      :vat_rate_bp,
      :vat_code,
      :line_total_cents,
      :line_vat_cents
    ])
    |> validate_required([
      :product_id,
      :product_name,
      :quantity,
      :unit_price_cents,
      :vat_rate_bp,
      :vat_code,
      :line_total_cents,
      :line_vat_cents
    ])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> assoc_constraint(:product)
  end
end
