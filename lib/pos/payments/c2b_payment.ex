defmodule Pos.Payments.C2BPayment do
  use Pos.Schema

  schema "mpesa_c2b_payments" do
    field :trans_id, :string
    field :transaction_type, :string
    field :amount_cents, :integer
    field :shortcode, :string
    field :bill_ref_number, :string
    field :msisdn_masked, :string
    field :payer_name, :string
    field :paid_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :claimed_by_sale_id, :binary_id
    field :raw_payload, :map

    timestamps()
  end
end
