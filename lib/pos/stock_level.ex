defmodule Pos.Inventory.StockLevel do
  @moduledoc "Cached running total. The stock_movements ledger is the source of truth."
  use Pos.Schema

  alias Pos.Catalog.Product

  @primary_key false

  schema "stock_levels" do
    belongs_to :product, Product, primary_key: true
    field :quantity, :decimal, default: Decimal.new(0)

    timestamps(inserted_at: false)
  end
end
