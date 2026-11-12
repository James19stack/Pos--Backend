defmodule Pos.Catalog.Product do
  use Pos.Schema

  alias Pos.Catalog.{Barcode, VatRate}
  alias Pos.Inventory.StockLevel

  schema "products" do
    field :sku, :string
    field :name, :string
    # Integer cents, VAT-inclusive. For weighed items this is the price per kg.
    field :price_cents, :integer
    field :cost_cents, :integer, default: 0
    field :is_weighed, :boolean, default: false
    field :unit, :string, default: "each"
    field :reorder_level, :decimal, default: Decimal.new(0)
    field :active, :boolean, default: true

    # KRA item registration (see Pos.Etims)
    field :etims_item_cd, :string
    field :etims_item_cls_cd, :string
    field :item_type_cd, :string, default: "2"
    field :origin_nation_cd, :string, default: "KE"
    field :pkg_unit_cd, :string
    field :qty_unit_cd, :string
    field :etims_registered_at, :utc_datetime_usec

    belongs_to :vat_rate, VatRate
    belongs_to :category, Pos.Catalog.Category
    has_many :barcodes, Barcode
    has_one :stock_level, StockLevel

    timestamps()
  end

  @fields [
    :sku, :name, :price_cents, :cost_cents, :is_weighed,
    :unit, :reorder_level, :active, :vat_rate_id,
    :etims_item_cls_cd, :pkg_unit_cd, :qty_unit_cd, :category_id
  ]

  def changeset(product, attrs) do
    product
    |> cast(attrs, @fields)
    |> validate_required([:sku, :name, :price_cents, :vat_rate_id])
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:reorder_level, greater_than_or_equal_to: 0)
    |> unique_constraint(:sku)
    |> assoc_constraint(:vat_rate)
    |> assoc_constraint(:category)
  end
end
