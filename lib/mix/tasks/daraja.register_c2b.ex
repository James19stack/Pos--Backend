defmodule Mix.Tasks.Daraja.RegisterC2b do
  @shortdoc "Registers the C2B confirmation/validation URLs with Daraja"
  @moduledoc """
  Run after setting DARAJA_CALLBACK_BASE_URL and DARAJA_CALLBACK_SECRET:

      set -a; source .env; set +a; mix daraja.register_c2b

  Sandbox: can be repeated freely. Production: one-time per shortcode. To change it
  later, delete the registration in the Daraja portal (Self Services > URL Management).
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    case Pos.Payments.C2B.register_urls() do
      {:ok, response} -> Mix.shell().info("Registered: #{inspect(response)}")
      {:error, reason} -> Mix.raise("Registration failed: #{inspect(reason)}")
    end
  end
end
