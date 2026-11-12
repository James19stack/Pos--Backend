defmodule Pos.Catalog.VatRate do
  use Pos.Schema

  schema "vat_rates" do
    field :code, :string
    field :name, :string
    # Basis points: 16% = 1600
    field :rate_bp, :integer

    timestamps()
  end

  def changeset(vat_rate, attrs) do
    vat_rate
    |> cast(attrs, [:code, :name, :rate_bp])
    |> validate_required([:code, :name, :rate_bp])
    |> validate_number(:rate_bp, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> unique_constraint(:code)
  end
end
