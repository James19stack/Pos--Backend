defmodule Pos.Repo.Migrations.CreateShifts do
  use Ecto.Migration

  def change do
    create table(:shifts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :device_id, :string, null: false
      add :status, :string, null: false, default: "open"
      add :opening_float_cents, :bigint, null: false, default: 0
      add :opened_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      # Filled at close. Expected is computed by the server, never typed in.
      add :counted_cash_cents, :bigint
      add :expected_cash_cents, :bigint
      add :difference_cents, :bigint
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :close_note, :string
      # The Z report, frozen at close so later changes can never rewrite it
      add :z_report, :map

      timestamps(type: :utc_datetime_usec)
    end

    # One cashier per drawer: a cashier has one open shift, and a till has one open shift
    create unique_index(:shifts, [:user_id],
             where: "status = 'open'",
             name: :shifts_one_open_per_user
           )

    create unique_index(:shifts, [:device_id],
             where: "status = 'open'",
             name: :shifts_one_open_per_device
           )

    create index(:shifts, [:status])
    create constraint(:shifts, :float_non_negative, check: "opening_float_cents >= 0")

    create constraint(:shifts, :status_must_be_valid,
             check: "status IN ('open','pending_approval','closed')"
           )

    alter table(:sales) do
      add :shift_id, references(:shifts, type: :binary_id, on_delete: :restrict)
    end

    create index(:sales, [:shift_id])
  end
end
