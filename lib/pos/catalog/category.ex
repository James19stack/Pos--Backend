defmodule Pos.Catalog.Category do
  use Pos.Schema

  schema "categories" do
    field :name, :string
    field :etims_item_cls_cd, :string
    field :pkg_unit_cd, :string
    field :qty_unit_cd, :string

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :etims_item_cls_cd, :pkg_unit_cd, :qty_unit_cd])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> unique_constraint(:name, name: :categories_name_ci_index, message: "already exists")
  end
end
