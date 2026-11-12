defmodule Pos.Repo.Migrations.CreateMpesaRequests do
  use Ecto.Migration

  def change do
    create table(:mpesa_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # The till's client-generated sale id. No foreign key: the sale does not
      # exist yet. It is only created once this payment is confirmed.
      add :sale_id, :binary_id, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :amount_cents, :bigint, null: false
      add :phone, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :merchant_request_id, :string
      add :checkout_request_id, :string
      add :receipt_number, :string
      add :result_code, :integer
      add :result_desc, :string
      add :paid_at, :utc_datetime_usec
      # Set when a sale uses this payment. Confirmed but never claimed = "paid, no sale".
      add :claimed_at, :utc_datetime_usec
      add :callback_payload, :map

      timestamps(type: :utc_datetime_usec)
    end

    # One live (pending or confirmed) request per sale: double taps cannot send two prompts.
    create unique_index(:mpesa_requests, [:sale_id],
             where: "status IN ('pending','confirmed')",
             name: :mpesa_requests_one_active_per_sale
           )

    create unique_index(:mpesa_requests, [:checkout_request_id],
             where: "checkout_request_id IS NOT NULL"
           )

    create unique_index(:mpesa_requests, [:receipt_number], where: "receipt_number IS NOT NULL")
    create index(:mpesa_requests, [:status, :inserted_at])

    create constraint(:mpesa_requests, :whole_shillings,
             check: "amount_cents >= 100 AND amount_cents % 100 = 0"
           )

    create constraint(:mpesa_requests, :status_must_be_valid,
             check: "status IN ('pending','confirmed','failed','timed_out')"
           )
  end
end
