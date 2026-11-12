defmodule Pos.Payments.FakeDaraja do
  @moduledoc """
  Stand-in for Safaricom in tests. Results are per test process, so tests stay async.
    FakeDaraja.set_push({:error, :timeout})   # make the next prompts fail
    FakeDaraja.set_query({:ok, %{result_code: 0, result_desc: "ok"}})
  Each prompt also sends {:stk_push, params} to the calling process.
  """
  @behaviour Pos.Payments.Daraja

  @impl true
  def stk_push(params) do
    send(self(), {:stk_push, params})

    case Process.get(:fake_daraja_push) do
      nil ->
        {:ok,
         %{
           checkout_request_id: "ws_CO_" <> Integer.to_string(System.unique_integer([:positive])),
           merchant_request_id: "29115-34620561-1"
         }}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def query(_checkout_request_id),
    do: Process.get(:fake_daraja_query, {:error, :still_processing})

  @impl true
  def register_c2b_urls(urls) do
    send(self(), {:register_c2b, urls})
    {:ok, %{"ResponseDescription" => "Success"}}
  end

  def set_push(result), do: Process.put(:fake_daraja_push, result)
  def set_query(result), do: Process.put(:fake_daraja_query, result)
end
