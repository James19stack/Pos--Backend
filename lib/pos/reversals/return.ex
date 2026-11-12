defmodule Pos.Reversals.Return do
  use Pos.Schema

  alias Pos.Accounts.User
  alias Pos.Reversals.ReturnItem
  alias Pos.Sales.Sale
  alias Pos.Shifts.Shift

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "returns" do
    field :reason, :string
    field :refund_method, :string, default: "cash"
    field :refund_cents, :integer
    field :refund_vat_cents, :integer

    belongs_to :sale, Sale
    belongs_to :shift, Shift
    belongs_to :user, User
    belongs_to :approved_by, User
    has_many :items, ReturnItem

    timestamps(updated_at: false)
  end
end
