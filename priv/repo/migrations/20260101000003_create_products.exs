defmodule Pos.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sku, :string, null: false
      add :name, :string, null: false

      add :vat_rate_id, references(:vat_rates, type: :binary_id, on_delete: :restrict),
        null: false

      # All money is integer cents (KES x 100). Selling price is VAT-inclusive.
      add :price_cents, :bigint, null: false
      add :cost_cents, :bigint, null: false, default: 0
      # Weighed items are sold by kg; price_cents is then per kg.
      add :is_weighed, :boolean, null: false, default: false
      add :unit, :string, null: false, default: "each"
      add :reorder_level, :decimal, precision: 12, scale: 3, null: false, default: 0
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:products, [:sku])
    create index(:products, [:vat_rate_id])

    create constraint(:products, :price_non_negative,
             check: "price_cents >= 0 AND cost_cents >= 0"
           )

    create table(:barcodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :code, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:barcodes, [:code])
    create index(:barcodes, [:product_id])
  end
end
