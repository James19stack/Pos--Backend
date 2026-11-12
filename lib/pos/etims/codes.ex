defmodule Pos.Etims.Codes do
  @moduledoc """
  The KRA codes that apply to a product: its own, else its category's, else (mock only)
  the placeholder defaults. Pass a product with `:category` preloaded.
  """
  alias Pos.Catalog.Category

  def resolve(product, defaults \\ %{}) do
    category = if match?(%Category{}, product.category), do: product.category, else: %{}

    %{
      item_cls_cd: product.etims_item_cls_cd || Map.get(category, :etims_item_cls_cd) || defaults[:item_cls_cd],
      pkg_unit_cd: product.pkg_unit_cd || Map.get(category, :pkg_unit_cd) || defaults[:pkg_unit_cd],
      qty_unit_cd: product.qty_unit_cd || Map.get(category, :qty_unit_cd) || defaults[:qty_unit_cd]
    }
  end
end
