defmodule Pos.Catalog.Barcode do
  use Pos.Schema

  alias Pos.Catalog.Product

  schema "barcodes" do
    field :code, :string
    belongs_to :product, Product

    timestamps(updated_at: false)
  end

  def changeset(barcode, attrs) do
    barcode
    |> cast(attrs, [:code, :product_id])
    |> validate_required([:code, :product_id])
    |> update_change(:code, &String.trim/1)
    |> unique_constraint(:code)
    |> assoc_constraint(:product)
  end
end
