defmodule Mix.Tasks.Daraja.SimulateC2b do
  @shortdoc "Sandbox only: fakes a customer paying the till/paybill"
  @moduledoc """
      mix daraja.simulate_c2b --amount 200
      mix daraja.simulate_c2b --amount 200 --ref ACC-1     (paybill only)

  Safaricom then POSTs a confirmation to your registered URL, so Phoenix and the
  tunnel must be running. Refuses to run against production.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    {opts, _, _} =
      OptionParser.parse(args, strict: [amount: :integer, msisdn: :integer, ref: :string])

    params = %{
      amount: opts[:amount] || 100,
      msisdn: opts[:msisdn] || 254_708_374_149,
      bill_ref: opts[:ref] || "TEST"
    }

    case Pos.Payments.Daraja.HTTP.simulate_c2b(params) do
      {:ok, response} -> Mix.shell().info("Simulated: #{inspect(response)}")
      {:error, reason} -> Mix.raise("Simulation failed: #{inspect(reason)}")
    end
  end
end
