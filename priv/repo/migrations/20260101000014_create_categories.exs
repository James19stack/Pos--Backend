defmodule Pos.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      # Defaults for every product in the category (KRA code lists). A product's own code wins.
      add :etims_item_cls_cd, :string
      add :pkg_unit_cd, :string
      add :qty_unit_cd, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:categories, ["lower(name)"], name: :categories_name_ci_index)

    alter table(:products) do
      add :category_id, references(:categories, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:products, [:category_id])
  end
end
