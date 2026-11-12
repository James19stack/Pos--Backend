defmodule Pos.Repo.Migrations.CreateStock do
  use Ecto.Migration

  def change do
    # Append-only ledger: the source of truth for stock. Never update or delete rows.
    create table(:stock_movements) do
      add :product_id, references(:products, type: :binary_id, on_delete: :restrict), null: false
      # Signed: positive = stock in, negative = stock out
      add :quantity, :decimal, precision: 12, scale: 3, null: false
      add :reason, :string, null: false
      # What caused it: a sale id, GRN id, stock take id, etc.
      add :reference_type, :string
      add :reference_id, :binary_id
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :note, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:stock_movements, [:product_id, :inserted_at])
    create index(:stock_movements, [:reference_type, :reference_id])

    create constraint(:stock_movements, :reason_must_be_valid,
             check:
               "reason IN ('sale','return','void','grn','adjustment','wastage','expiry','stocktake','opening')"
           )

    # Cached running total, updated in the same transaction as each movement.
    # Can always be rebuilt by summing stock_movements.
    create table(:stock_levels, primary_key: false) do
      add :product_id, references(:products, type: :binary_id, on_delete: :restrict),
        primary_key: true

      add :quantity, :decimal, precision: 12, scale: 3, null: false, default: 0

      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end
  end
end
