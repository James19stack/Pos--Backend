defmodule Pos.Inventory.StockMovement do
  use Pos.Schema

  alias Pos.Accounts.User
  alias Pos.Catalog.Product

  # bigserial id, unlike the UUID tables
  @primary_key {:id, :id, autogenerate: true}

  @reasons [:sale, :return, :void, :grn, :adjustment, :wastage, :expiry, :stocktake, :opening]

  schema "stock_movements" do
    # Signed: positive = in, negative = out
    field :quantity, :decimal
    field :reason, Ecto.Enum, values: @reasons
    field :reference_type, :string
    field :reference_id, :binary_id
    field :note, :string

    belongs_to :product, Product
    belongs_to :user, User

    timestamps(updated_at: false)
  end

  def reasons, do: @reasons

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :product_id,
      :quantity,
      :reason,
      :reference_type,
      :reference_id,
      :user_id,
      :note
    ])
    |> validate_required([:product_id, :quantity, :reason])
    |> validate_change(:quantity, fn :quantity, q ->
      if Decimal.eq?(q, 0), do: [quantity: "must not be zero"], else: []
    end)
    |> assoc_constraint(:product)
  end
end
