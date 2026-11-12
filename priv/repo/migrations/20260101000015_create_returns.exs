defmodule Pos.Repo.Migrations.CreateReturns do
  use Ecto.Migration

  def change do
    alter table(:sales) do
      add :voided_at, :utc_datetime_usec
      add :voided_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :void_reason, :string
      add :void_approved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create table(:returns, primary_key: false) do
      # Client-generated: a retried return can never refund twice
      add :id, :binary_id, primary_key: true
      add :sale_id, references(:sales, type: :binary_id, on_delete: :restrict), null: false
      # The drawer the refund came out of (the processing cashier's open shift, not the sale's)
      add :shift_id, references(:shifts, type: :binary_id, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :reason, :string, null: false
      # cash: paid from the drawer. other: refunded outside the system (M-Pesa, card): no drawer effect
      add :refund_method, :string, null: false, default: "cash"
      add :refund_cents, :bigint, null: false
      add :refund_vat_cents, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:returns, [:sale_id])
    create index(:returns, [:shift_id])
    create constraint(:returns, :refund_method_valid, check: "refund_method IN ('cash','other')")

    create table(:return_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :return_id, references(:returns, type: :binary_id, on_delete: :delete_all), null: false
      add :sale_item_id, references(:sale_items, type: :binary_id, on_delete: :restrict), null: false
      add :product_id, references(:products, type: :binary_id, on_delete: :restrict), null: false
      add :quantity, :decimal, precision: 12, scale: 3, null: false
      add :refund_cents, :bigint, null: false
      add :refund_vat_cents, :bigint, null: false
    end

    create index(:return_items, [:return_id])
    create index(:return_items, [:sale_item_id])
    create constraint(:return_items, :quantity_positive, check: "quantity > 0")
  end
end
