defmodule Pos.Repo.Migrations.CreateGoodsReceipts do
  use Ecto.Migration

  def change do
    create table(:goods_receipts, primary_key: false) do
      # Client-generated, like sales: posting the same receipt twice is harmless
      add :id, :binary_id, primary_key: true
      add :supplier_name, :string
      add :reference, :string
      add :note, :string
      add :received_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :received_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:goods_receipts, [:received_at])

    create table(:goods_receipt_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goods_receipt_id, references(:goods_receipts, type: :binary_id, on_delete: :delete_all), null: false
      add :product_id, references(:products, type: :binary_id, on_delete: :restrict), null: false
      add :quantity, :decimal, precision: 12, scale: 3, null: false
      add :unit_cost_cents, :bigint, null: false, default: 0
    end

    create index(:goods_receipt_items, [:goods_receipt_id])
    create index(:goods_receipt_items, [:product_id])
    create constraint(:goods_receipt_items, :quantity_positive, check: "quantity > 0")
  end
end
