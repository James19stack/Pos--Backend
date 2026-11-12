defmodule Pos.Payments.Daraja do
  @moduledoc """
  The slice of Safaricom's Daraja API this system uses. Production code talks to
  Pos.Payments.Daraja.HTTP; tests swap in a fake via
  `config :pos, :daraja_client, Pos.Payments.FakeDaraja`.
  """

  @type push_params :: %{
          amount: pos_integer(),
          phone: String.t(),
          account_reference: String.t(),
          description: String.t(),
          callback_url: String.t()
        }

  @callback stk_push(push_params()) ::
              {:ok, %{checkout_request_id: String.t(), merchant_request_id: String.t()}}
              | {:error, term()}

  @callback query(checkout_request_id :: String.t()) ::
              {:ok, %{result_code: integer(), result_desc: String.t() | nil}} | {:error, term()}

  @callback register_c2b_urls(%{confirmation_url: String.t(), validation_url: String.t()}) ::
              {:ok, map()} | {:error, term()}

  def impl, do: Application.get_env(:pos, :daraja_client, Pos.Payments.Daraja.HTTP)
end
