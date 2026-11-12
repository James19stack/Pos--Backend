defmodule Pos.Sales.Sale do
  use Pos.Schema

  alias Pos.Accounts.User
  alias Pos.Payments.Payment
  alias Pos.Sales.SaleItem

  # Client-generated UUID, so retries and offline sync hit the same row.
  @primary_key {:id, :binary_id, autogenerate: false}

  @statuses [:held, :completed, :voided, :refunded]
  @etims_statuses [:pending, :submitted, :accepted, :failed]

  schema "sales" do
    field :device_id, :string
    field :receipt_no, :string
    field :status, Ecto.Enum, values: @statuses, default: :completed
    field :subtotal_cents, :integer
    field :discount_cents, :integer, default: 0
    field :vat_cents, :integer
    field :total_cents, :integer
    field :sold_at, :utc_datetime_usec
    field :etims_status, Ecto.Enum, values: @etims_statuses, default: :pending
    field :etims_invoice_no, :string
    field :needs_review, :boolean, default: false
    field :voided_at, :utc_datetime_usec
    field :void_reason, :string
    field :voided_by_id, :binary_id
    field :void_approved_by_id, :binary_id

    belongs_to :cashier, User
    belongs_to :shift, Pos.Shifts.Shift
    has_many :items, SaleItem
    has_many :payments, Payment

    timestamps()
  end

  @doc """
  Built from server-computed attrs. The Sales context looks up prices and VAT
  itself and never trusts totals sent by the client.
  """
  def changeset(sale, attrs) do
    sale
    |> cast(attrs, [
      :id, :cashier_id, :device_id, :receipt_no, :status, :subtotal_cents,
      :discount_cents, :vat_cents, :total_cents, :sold_at, :needs_review, :shift_id
    ])
    |> validate_required([:id, :cashier_id, :subtotal_cents, :vat_cents, :total_cents, :sold_at])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> cast_assoc(:items, required: true)
    |> cast_assoc(:payments)
    |> unique_constraint(:id, name: :sales_pkey)
    |> unique_constraint(:receipt_no)
    |> assoc_constraint(:cashier)
  end
end
