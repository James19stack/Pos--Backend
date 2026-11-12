defmodule Pos.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :citext, null: false
      add :password_hash, :string, null: false
      add :pin_hash, :string
      add :role, :string, null: false, default: "cashier"
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create constraint(:users, :role_must_be_valid,
             check: "role IN ('cashier','supervisor','manager','admin')"
           )
  end
end
