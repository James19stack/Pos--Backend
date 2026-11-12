defmodule Pos.Reversals.ReturnItem do
  use Pos.Schema

  alias Pos.Catalog.Product
  alias Pos.Reversals.Return
  alias Pos.Sales.SaleItem

  schema "return_items" do
    field :quantity, :decimal
    field :refund_cents, :integer
    field :refund_vat_cents, :integer

    belongs_to :return, Return
    belongs_to :sale_item, SaleItem
    belongs_to :product, Product
  end
end
