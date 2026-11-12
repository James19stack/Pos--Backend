defmodule Pos.Etims.Provider.Mock do
  @moduledoc """
  A stand-in for KRA. Its "signatures" start with MOCK so nobody can mistake them for a
  real tax invoice, and receipts show a TEST MODE banner while it is in use.
  Tests steer it per process: `Mock.set_result({:error, :timeout})`, `Mock.set_result(nil)`.
  """
  @behaviour Pos.Etims.Provider

  @impl true
  def save_item(payload) do
    send(self(), {:etims_save_item, payload})

    case Process.get(:etims_mock_result) do
      {:error, _} = error -> error
      _ -> {:ok, %{}}
    end
  end

  @impl true
  def submit_sale(payload) do
    send(self(), {:etims_submit, payload})

    case Process.get(:etims_mock_result) do
      {:error, _} = error ->
        error

      _ ->
        digest = :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode32(padding: false)

        {:ok,
         %{
           receipt_no: payload["invcNo"],
           total_receipt_no: payload["invcNo"],
           internal_data: "MOCK" <> binary_part(digest, 0, 22),
           receipt_signature: "MOCK" <> binary_part(digest, 22, 12),
           sdc_datetime: DateTime.utc_now() |> DateTime.add(3 * 3600, :second) |> Calendar.strftime("%Y%m%d%H%M%S"),
           sdc_id: "MOCK-SDC"
         }}
    end
  end

  def set_result(result), do: Process.put(:etims_mock_result, result)
end
