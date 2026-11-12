defmodule Pos.Inventory.GoodsReceiptItem do
  use Pos.Schema

  alias Pos.Catalog.Product
  alias Pos.Inventory.GoodsReceipt

  schema "goods_receipt_items" do
    field :quantity, :decimal
    field :unit_cost_cents, :integer, default: 0

    belongs_to :goods_receipt, GoodsReceipt
    belongs_to :product, Product
  end
end
