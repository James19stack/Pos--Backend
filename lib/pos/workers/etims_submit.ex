defmodule Pos.Workers.EtimsSubmit do
  @moduledoc "Files one invoice with KRA. Retries with growing delays, so a KRA outage never loses an invoice."
  use Oban.Worker, queue: :etims, max_attempts: 25

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invoice_id" => invoice_id}}) do
    case Pos.Etims.submit(invoice_id) do
      {:ok, _invoice} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # 30s, 2 min, 4.5 min ... capped at an hour
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(30 * attempt * attempt, 3600)
end
