defmodule Pos.Repo.Migrations.CreateMpesaC2bPayments do
  use Ecto.Migration

  def change do
    create table(:mpesa_c2b_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Safaricom's transaction code, the one in the customer's SMS (e.g. RKTQDM7W6S)
      add :trans_id, :string, null: false
      add :transaction_type, :string
      add :amount_cents, :bigint, null: false
      add :shortcode, :string
      add :bill_ref_number, :string
      # Daraja v2 masks the phone (2547*****126): we match on trans_id, never on phone
      add :msisdn_masked, :string
      add :payer_name, :string
      add :paid_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      add :claimed_by_sale_id, :binary_id
      add :raw_payload, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mpesa_c2b_payments, [:trans_id])
    create index(:mpesa_c2b_payments, [:claimed_at])
    create constraint(:mpesa_c2b_payments, :amount_positive, check: "amount_cents > 0")
  end
end
