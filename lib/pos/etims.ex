defmodule Pos.Etims do
  @moduledoc """
  KRA eTIMS invoicing. After a sale is saved, `enqueue/1` gives it the next gap-free invoice
  number and queues a job; the job calls `submit/1`, which registers any unregistered
  products with KRA, then files the invoice. A KRA problem NEVER blocks or undoes a sale:
  the invoice just stays pending and is retried.

  Until the real OSCU client exists everything runs against Provider.Mock, and receipts are
  marked TEST MODE (see `mode/0`).
  """
  import Ecto.Query, warn: false
  require Logger

  alias Pos.Catalog.Product
  alias Pos.Etims.{Codes, Invoice, Payload, Provider}
  alias Pos.Repo
  alias Pos.Sales.Sale

  def config do
    c = Application.get_env(:pos, :etims, [])

    %{
      tin: c[:tin] || "P000000000A",
      bhf_id: c[:bhf_id] || "00",
      trade_name: c[:trade_name] || "Supermarket",
      address: c[:address] || "",
      top_msg: c[:top_msg] || "",
      btm_msg: c[:btm_msg] || "Thank you for shopping with us",
      taxable_basis: c[:taxable_basis] || :gross,
      # PLACEHOLDER codes, used only with the mock. The real client requires each product to carry
      # codes from KRA's code lists, and refuses to guess them.
      defaults: Map.new(c[:defaults] || [pkg_unit_cd: "NT", qty_unit_cd: "U", item_cls_cd: "5059690800"])
    }
  end

  @doc "eTIMS is OFF unless `config :pos, :etims_enabled, true`. Off means no invoices, no jobs, no banners."
  def enabled?, do: Application.get_env(:pos, :etims_enabled, false)

  def accepted?(sale_id) do
    match?(%Invoice{status: :accepted}, get_invoice_for_sale(sale_id))
  end

  def mode, do: if(Provider.impl() == Provider.Mock, do: "mock", else: "oscu")

  ## Reading

  def get_invoice_for_sale(sale_id), do: Repo.get_by(Invoice, sale_id: sale_id)

  def list_pending(min_age_seconds \\ 120) do
    cutoff = DateTime.add(DateTime.utc_now(), -min_age_seconds, :second)
    pending = :pending

    Repo.all(from i in Invoice, where: i.status == ^pending and i.inserted_at < ^cutoff, order_by: i.invoice_no)
  end

  def load_sale(sale_id) do
    Sale |> Repo.get!(sale_id) |> Repo.preload([:payments, :cashier, items: [product: :category]])
  end

  ## Queueing (called right after a sale commits)

  def enqueue(%Sale{} = sale) do
    if enabled?(), do: do_enqueue(sale), else: {:ok, nil}
  end

  defp do_enqueue(%Sale{} = sale) do
    Repo.transaction(fn ->
      case get_invoice_for_sale(sale.id) do
        %Invoice{} = existing ->
          existing

        nil ->
          branch = config().bhf_id

          invoice =
            Repo.insert!(%Invoice{sale_id: sale.id, branch_id: branch, invoice_no: next_number("invoice:" <> branch), mode: mode()})

          # Same transaction as the number: both exist or neither does
          Oban.insert!(Pos.Workers.EtimsSubmit.new(%{"invoice_id" => invoice.id}))
          invoice
      end
    end)
  rescue
    e ->
      Logger.error("Could not queue eTIMS invoice for sale #{sale.id}: #{Exception.message(e)}")
      {:error, :enqueue_failed}
  end

  @doc "Gap-free: runs inside the caller's transaction, so a rollback gives the number back."
  def next_number(key) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO etims_counters (key, last_number) VALUES ($1, 1) ON CONFLICT (key) DO UPDATE SET last_number = etims_counters.last_number + 1 RETURNING last_number",
        [key]
      )

    n
  end

  ## Filing

  @doc "Files one invoice. Safe to call again: an accepted invoice is never sent twice."
  def submit(invoice_id) do
    Repo.transaction(
      fn ->
        # Row lock: the job and a manual retry can never file the same invoice together
        invoice = Repo.one!(from i in Invoice, where: i.id == ^invoice_id, lock: "FOR UPDATE")

        if invoice.status == :accepted, do: {:ok, invoice}, else: file(invoice)
      end,
      timeout: 60_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp file(invoice) do
    invoice = invoice |> Ecto.Changeset.change(attempts: invoice.attempts + 1) |> Repo.update!()
    sale = load_sale(invoice.sale_id)

    with :ok <- ensure_items_registered(sale),
         sale = load_sale(invoice.sale_id),
         payload = Payload.build(sale, invoice.invoice_no, config()),
         {:ok, response} <- Provider.impl().submit_sale(payload) do
      accept(invoice, sale, payload, response)
    else
      {:error, reason} ->
        invoice |> Ecto.Changeset.change(last_error: inspect(reason)) |> Repo.update!()
        {:error, reason}
    end
  end

  defp accept(invoice, sale, payload, r) do
    accepted =
      invoice
      |> Ecto.Changeset.change(%{
        status: :accepted,
        last_error: nil,
        receipt_no: r.receipt_no,
        total_receipt_no: r.total_receipt_no,
        internal_data: r.internal_data,
        receipt_signature: r.receipt_signature,
        sdc_datetime: r.sdc_datetime,
        sdc_id: r.sdc_id,
        request: payload,
        response: r,
        submitted_at: DateTime.utc_now()
      })
      |> Repo.update!()

    sale |> Ecto.Changeset.change(etims_status: :accepted, etims_invoice_no: Integer.to_string(invoice.invoice_no)) |> Repo.update!()
    {:ok, accepted}
  end

  ## Items must be registered with KRA before they can appear on an invoice

  defp ensure_items_registered(sale) do
    sale.items
    |> Enum.map(& &1.product)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while(:ok, fn product, :ok ->
      if product.etims_registered_at do
        {:cont, :ok}
      else
        case register_item(product) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end

  defp register_item(%Product{} = product) do
    defaults = if Provider.impl() == Provider.Mock, do: config().defaults, else: %{}
    %{item_cls_cd: cls, pkg_unit_cd: pkg, qty_unit_cd: qty} = Codes.resolve(Repo.preload(product, :category), defaults)

    if cls && pkg && qty do
      # Item code: country + type + packaging unit + quantity unit + 7-digit serial
      code =
        product.etims_item_cd ||
          product.origin_nation_cd <> product.item_type_cd <> pkg <> qty <> (next_number("items") |> Integer.to_string() |> String.pad_leading(7, "0"))

      product = product |> Ecto.Changeset.change(etims_item_cd: code) |> Repo.update!()

      payload = %{
        "tin" => config().tin,
        "bhfId" => config().bhf_id,
        "itemCd" => code,
        "itemClsCd" => cls,
        "itemTyCd" => product.item_type_cd,
        "itemNm" => product.name,
        "orgnNatCd" => product.origin_nation_cd,
        "pkgUnitCd" => pkg,
        "qtyUnitCd" => qty,
        "taxTyCd" => Repo.preload(product, :vat_rate).vat_rate.code,
        "bcd" => nil,
        "dftPrc" => Payload.kes(product.price_cents),
        "isrcAplcbYn" => "N",
        "useYn" => "Y",
        "regrId" => "pos",
        "regrNm" => "POS system",
        "modrId" => "pos",
        "modrNm" => "POS system"
      }

      with {:ok, _} <- Provider.impl().save_item(payload) do
        product |> Ecto.Changeset.change(etims_registered_at: DateTime.utc_now()) |> Repo.update!()
        :ok
      end
    else
      {:error, {:product_missing_etims_codes, product.sku}}
    end
  end
end
