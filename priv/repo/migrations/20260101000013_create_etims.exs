defmodule Pos.Repo.Migrations.CreateEtims do
  use Ecto.Migration

  def change do
    alter table(:products) do
      # KRA item registration data. Codes come from KRA's code lists (selectCodeList / selectItemClsList).
      add :etims_item_cd, :string
      add :etims_item_cls_cd, :string
      add :item_type_cd, :string, default: "2"
      add :origin_nation_cd, :string, default: "KE"
      add :pkg_unit_cd, :string
      add :qty_unit_cd, :string
      add :etims_registered_at, :utc_datetime_usec
    end

    create unique_index(:products, [:etims_item_cd], where: "etims_item_cd IS NOT NULL")

    # Gap-free numbering: bumped inside the same transaction that stores the number
    create table(:etims_counters, primary_key: false) do
      add :key, :string, primary_key: true
      add :last_number, :bigint, null: false, default: 0
    end

    create table(:etims_invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sale_id, references(:sales, type: :binary_id, on_delete: :restrict), null: false
      add :branch_id, :string, null: false
      add :invoice_no, :bigint, null: false
      add :status, :string, null: false, default: "pending"
      add :mode, :string, null: false, default: "mock"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      # What KRA returned: these belong on the printed receipt
      add :receipt_no, :bigint
      add :total_receipt_no, :bigint
      add :internal_data, :string
      add :receipt_signature, :string
      add :sdc_datetime, :string
      add :sdc_id, :string
      add :request, :map
      add :response, :map
      add :submitted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:etims_invoices, [:sale_id])
    create unique_index(:etims_invoices, [:branch_id, :invoice_no])
    create index(:etims_invoices, [:status, :inserted_at])
    create constraint(:etims_invoices, :status_must_be_valid, check: "status IN ('pending','accepted')")
  end
end
