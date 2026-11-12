defmodule Pos.Payments.MpesaRequest do
  use Pos.Schema

  alias Pos.Accounts.User

  @statuses [:pending, :confirmed, :failed, :timed_out]

  schema "mpesa_requests" do
    field :sale_id, :binary_id
    field :amount_cents, :integer
    field :phone, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :merchant_request_id, :string
    field :checkout_request_id, :string
    field :receipt_number, :string
    field :result_code, :integer
    field :result_desc, :string
    field :paid_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :callback_payload, :map

    belongs_to :user, User

    timestamps()
  end

  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [:sale_id, :user_id, :amount_cents, :phone])
    |> validate_required([:sale_id, :amount_cents, :phone])
    |> check_constraint(:amount_cents, name: :whole_shillings, message: "must be whole shillings")
    |> unique_constraint(:sale_id, name: :mpesa_requests_one_active_per_sale)
  end
end
