defmodule Pos.Repo.Migrations.CreateSales do
  use Ecto.Migration

  def change do
    create table(:sales, primary_key: false) do
      # Client-generated UUID: makes offline queueing and idempotent sync possible.
      add :id, :binary_id, primary_key: true
      add :cashier_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :device_id, :string
      add :receipt_no, :string
      add :status, :string, null: false, default: "completed"
      add :subtotal_cents, :bigint, null: false
      add :discount_cents, :bigint, null: false, default: 0
      add :vat_cents, :bigint, null: false
      add :total_cents, :bigint, null: false
      # When the sale happened on the till (may be earlier than inserted_at if offline)
      add :sold_at, :utc_datetime_usec, null: false
      # Set by Oban job once the eTIMS invoice is accepted
      add :etims_status, :string, null: false, default: "pending"
      add :etims_invoice_no, :string
      add :needs_review, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sales, [:cashier_id])
    create index(:sales, [:sold_at])
    create index(:sales, [:etims_status])
    create unique_index(:sales, [:receipt_no])

    create constraint(:sales, :status_must_be_valid,
             check: "status IN ('held','completed','voided','refunded')"
           )

    create constraint(:sales, :totals_non_negative,
             check: "subtotal_cents >= 0 AND vat_cents >= 0 AND total_cents >= 0"
           )

    create table(:sale_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sale_id, references(:sales, type: :binary_id, on_delete: :delete_all), null: false
      add :product_id, references(:products, type: :binary_id, on_delete: :restrict), null: false
      # Snapshots, so later price or name changes never alter past sales
      add :product_name, :string, null: false
      add :barcode, :string
      add :quantity, :decimal, precision: 12, scale: 3, null: false
      add :unit_price_cents, :bigint, null: false
      add :vat_rate_bp, :integer, null: false
      add :vat_code, :string, null: false
      add :line_total_cents, :bigint, null: false
      add :line_vat_cents, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sale_items, [:sale_id])
    create index(:sale_items, [:product_id])
    create constraint(:sale_items, :quantity_positive, check: "quantity > 0")
  end
end
