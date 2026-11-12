defmodule Pos.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sale_id, references(:sales, type: :binary_id, on_delete: :restrict), null: false
      add :method, :string, null: false
      add :status, :string, null: false, default: "confirmed"
      # Amount applied to the sale (excludes change given)
      add :amount_cents, :bigint, null: false
      # Cash only: what the customer handed over
      add :tendered_cents, :bigint
      # M-Pesa receipt code, card approval code, etc.
      add :reference, :string
      # M-Pesa STK Push correlation ids
      add :checkout_request_id, :string
      add :phone, :string
      add :raw_response, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:payments, [:sale_id])
    create index(:payments, [:status])

    create unique_index(:payments, [:checkout_request_id],
             where: "checkout_request_id IS NOT NULL"
           )

    create unique_index(:payments, [:method, :reference],
             where: "reference IS NOT NULL",
             name: :payments_method_reference_index
           )

    create constraint(:payments, :method_must_be_valid,
             check: "method IN ('cash','mpesa','card')"
           )

    create constraint(:payments, :status_must_be_valid,
             check: "status IN ('pending','confirmed','failed','timed_out')"
           )

    create constraint(:payments, :amount_positive, check: "amount_cents > 0")
  end
end
