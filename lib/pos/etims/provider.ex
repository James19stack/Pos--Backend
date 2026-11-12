defmodule Pos.Etims.Provider do
  @moduledoc """
  What we need from KRA. `Provider.Mock` answers locally (development and tests);
  `Provider.OSCU` will talk to KRA once the integration token and current URLs are known.
  Choose with `config :pos, :etims_provider, Pos.Etims.Provider.Mock`.
  """

  @type sale_result :: %{
          receipt_no: integer(),
          total_receipt_no: integer(),
          internal_data: String.t(),
          receipt_signature: String.t(),
          sdc_datetime: String.t(),
          sdc_id: String.t() | nil
        }

  @callback save_item(map()) :: {:ok, map()} | {:error, term()}
  @callback submit_sale(map()) :: {:ok, sale_result()} | {:error, term()}

  def impl, do: Application.get_env(:pos, :etims_provider, Pos.Etims.Provider.Mock)
end
