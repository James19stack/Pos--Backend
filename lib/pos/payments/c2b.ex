defmodule Pos.Payments.C2B do
  @moduledoc """
  Payments customers make straight to the till or paybill (no STK prompt).

  Safaricom POSTs every such payment to our registered Confirmation URL; we store it
  by its transaction code. At the till the cashier types the code from the customer's
  SMS. A code that is not in our table is not a payment (fake SMS), and a code can be
  used for one sale only.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Pos.Payments.{C2BPayment, Daraja, Mpesa}
  alias Pos.Repo

  @doc "Stores a Confirmation payload. Safaricom may repeat itself, so duplicates are harmless."
  def record_confirmation(%{"TransID" => trans_id} = p)
      when is_binary(trans_id) and trans_id != "" do
    case Mpesa.to_cents(p["TransAmount"]) do
      cents when is_integer(cents) and cents > 0 ->
        Repo.insert(
          %C2BPayment{
            trans_id: normalize(trans_id),
            transaction_type: p["TransactionType"],
            amount_cents: cents,
            shortcode: p["BusinessShortCode"] && to_string(p["BusinessShortCode"]),
            bill_ref_number: p["BillRefNumber"],
            msisdn_masked: p["MSISDN"] && to_string(p["MSISDN"]),
            payer_name: payer_name(p),
            paid_at: Mpesa.usec(Mpesa.parse_date(p["TransTime"]) || DateTime.utc_now()),
            raw_payload: p
          },
          on_conflict: :nothing,
          conflict_target: :trans_id
        )

      _ ->
        Logger.error("C2B confirmation with unreadable amount, transaction #{trans_id}")
        :ignored
    end
  end

  def record_confirmation(_), do: :ignored

  def get_by_code(code) when is_binary(code),
    do: Repo.get_by(C2BPayment, trans_id: normalize(code))

  def get_by_code(_), do: nil

  @doc "Read-only check, run before the sale transaction."
  def fetch_claimable(code, amount_cents) do
    case get_by_code(code) do
      nil -> {:error, :c2b_payment_not_found}
      %{claimed_at: %DateTime{}} -> {:error, :c2b_payment_already_used}
      %{amount_cents: a} when a != amount_cents -> {:error, :c2b_amount_mismatch}
      payment -> {:ok, payment}
    end
  end

  @doc "Marks a payment as used by a sale. Locks the row, so it can only happen once."
  def claim(repo, payment_id, sale_id) do
    payment = repo.one!(from p in C2BPayment, where: p.id == ^payment_id, lock: "FOR UPDATE")

    if payment.claimed_at do
      {:error, :c2b_payment_already_used}
    else
      payment
      |> Ecto.Changeset.change(claimed_at: DateTime.utc_now(), claimed_by_sale_id: sale_id)
      |> repo.update()
    end
  end

  @doc "Registers our Confirmation and Validation URLs with Daraja (`mix daraja.register_c2b`)."
  def register_urls do
    cfg = Application.get_env(:pos, :daraja, [])

    base =
      String.trim_trailing(cfg[:callback_base_url] || "", "/") <>
        "/api/callbacks/daraja/" <> (cfg[:callback_secret] || "")

    Daraja.impl().register_c2b_urls(%{
      confirmation_url: base <> "/c2b/confirmation",
      validation_url: base <> "/c2b/validation"
    })
  end

  defp normalize(code), do: code |> String.trim() |> String.upcase()

  defp payer_name(p) do
    name =
      [p["FirstName"], p["MiddleName"], p["LastName"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    if name == "", do: nil, else: name
  end
end
