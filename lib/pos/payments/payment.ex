defmodule Pos.Payments.Payment do
  use Pos.Schema

  alias Pos.Sales.Sale

  @methods [:cash, :mpesa, :card]
  @statuses [:pending, :confirmed, :failed, :timed_out]

  schema "payments" do
    field :method, Ecto.Enum, values: @methods
    field :status, Ecto.Enum, values: @statuses, default: :confirmed
    # Amount applied to the sale (change given is excluded)
    field :amount_cents, :integer
    field :tendered_cents, :integer
    field :reference, :string
    field :checkout_request_id, :string
    field :phone, :string
    field :raw_response, :map

    belongs_to :sale, Sale

    timestamps()
  end

  def methods, do: @methods

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :method,
      :status,
      :amount_cents,
      :tendered_cents,
      :reference,
      :checkout_request_id,
      :phone,
      :raw_response
    ])
    |> validate_required([:method, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_cash_tendered()
    |> unique_constraint(:checkout_request_id)
    |> unique_constraint([:method, :reference], name: :payments_method_reference_index)
  end

  defp validate_cash_tendered(changeset) do
    if get_field(changeset, :method) == :cash do
      amount = get_field(changeset, :amount_cents)
      tendered = get_field(changeset, :tendered_cents) || amount

      if is_integer(amount) and tendered < amount do
        add_error(changeset, :tendered_cents, "is less than the amount due")
      else
        changeset
      end
    else
      changeset
    end
  end
end
