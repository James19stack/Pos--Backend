defmodule Pos.Workers.MpesaReconciler do
  @moduledoc "Every minute: ask Daraja about pending M-Pesa requests whose callback never came."
  use Oban.Worker, queue: :mpesa, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Pos.Payments.Mpesa.reconcile_pending()
    :ok
  end
end
