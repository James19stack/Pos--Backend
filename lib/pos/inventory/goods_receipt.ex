defmodule Pos.Inventory.GoodsReceipt do
  use Pos.Schema

  alias Pos.Accounts.User
  alias Pos.Inventory.GoodsReceiptItem

  # Client-generated id, so retries cannot post the same delivery twice
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "goods_receipts" do
    field :supplier_name, :string
    field :reference, :string
    field :note, :string
    field :received_at, :utc_datetime_usec

    belongs_to :received_by, User
    has_many :items, GoodsReceiptItem

    timestamps(updated_at: false)
  end
end
