defmodule Pos.Repo.Migrations.CreateVatRates do
  use Ecto.Migration

  def change do
    create table(:vat_rates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # eTIMS tax type code (A, B, C, D, E). Confirm against the current KRA spec.
      add :code, :string, null: false
      add :name, :string, null: false
      # Basis points: 16% = 1600, 8% = 800, 0% = 0
      add :rate_bp, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vat_rates, [:code])
    create constraint(:vat_rates, :rate_bp_range, check: "rate_bp >= 0 AND rate_bp <= 10000")
  end
end
