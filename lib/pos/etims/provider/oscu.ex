defmodule Pos.Etims.Provider.OSCU do
  @moduledoc """
  The real KRA client. NOT BUILT YET: it needs the integration token, the current base URL
  and the exact authentication scheme (the spec's `tin` / `bhfId` / `cmcKey` in each body,
  possibly with a GavaConnect bearer token on top). Until then it refuses to run, so the
  system can never silently pretend to have filed an invoice.
  """
  @behaviour Pos.Etims.Provider

  @impl true
  def save_item(_payload), do: {:error, :oscu_client_not_built}

  @impl true
  def submit_sale(_payload), do: {:error, :oscu_client_not_built}
end
