defmodule Pos.Etims.Payload do
  @moduledoc """
  Builds the sales-invoice body (`saveTrnsSalesOsdc`) from a stored sale, following the
  OSCU specification v2.0. Field names and the tax-basis choice must be confirmed against
  KRA's sandbox tests: the spec's own sample shows `taxblAmt` equal to the gross total, so
  that is the default (`taxable_basis: :gross`); switch to `:net` if the sandbox disagrees.

  Our amounts are VAT-inclusive cents; KRA wants currency units, so cents / 100.
  The provider adds the device key (`cmcKey`) when it sends.
  """
  alias Pos.Sales.Sale

  @bands ~w(A B C D E)
  # Rates for bands with no lines on the invoice: A exempt, B 16%, C zero, D non-VAT, E 8%
  @default_bp %{"A" => 0, "B" => 1600, "C" => 0, "D" => 0, "E" => 800}
  @pmt %{cash: "01", card: "05", mpesa: "06"}

  def build(%Sale{} = sale, invoice_no, cfg) do
    by_band = Enum.group_by(sale.items, & &1.vat_code)

    bands =
      Map.new(@bands, fn code ->
        lines = Map.get(by_band, code, [])
        gross = lines |> Enum.map(& &1.line_total_cents) |> Enum.sum()
        tax = lines |> Enum.map(& &1.line_vat_cents) |> Enum.sum()
        bp = (List.first(lines) || %{vat_rate_bp: @default_bp[code]}).vat_rate_bp
        {code, %{taxable: taxable(gross, tax, cfg.taxable_basis), tax: tax, bp: bp}}
      end)

    band_fields =
      Enum.reduce(@bands, %{}, fn code, acc ->
        b = bands[code]

        acc
        |> Map.put("taxblAmt" <> code, kes(b.taxable))
        |> Map.put("taxRt" <> code, kes(b.bp))
        |> Map.put("taxAmt" <> code, kes(b.tax))
      end)

    cashier = sale.cashier

    Map.merge(band_fields, %{
      "tin" => cfg.tin,
      "bhfId" => cfg.bhf_id,
      "trdInvcNo" => sale.id,
      "invcNo" => invoice_no,
      "orgInvcNo" => 0,
      "custTin" => nil,
      "custNm" => nil,
      "salesTyCd" => "N",
      "rcptTyCd" => "S",
      "pmtTyCd" => payment_code(sale.payments),
      "salesSttsCd" => "02",
      "cfmDt" => eat(sale.sold_at),
      "salesDt" => sale.sold_at |> eat() |> binary_part(0, 8),
      "totItemCnt" => length(sale.items),
      "totTaxblAmt" => kes(bands |> Map.values() |> Enum.map(& &1.taxable) |> Enum.sum()),
      "totTaxAmt" => kes(sale.vat_cents),
      "totAmt" => kes(sale.total_cents),
      "prchrAcptcYn" => "N",
      "regrId" => cashier.id,
      "regrNm" => cashier.name,
      "modrId" => cashier.id,
      "modrNm" => cashier.name,
      "receipt" => %{
        "custTin" => nil,
        "custMblNo" => nil,
        "rptNo" => invoice_no,
        "trdeNm" => cfg.trade_name,
        "adrs" => cfg.address,
        "topMsg" => cfg.top_msg,
        "btmMsg" => cfg.btm_msg,
        "prchrAcptcYn" => "N"
      },
      "itemList" => sale.items |> Enum.with_index(1) |> Enum.map(&item(&1, cfg))
    })
  end

  defp item({i, seq}, cfg) do
    p = i.product
    codes = Pos.Etims.Codes.resolve(p, cfg.defaults)

    %{
      "itemSeq" => seq,
      "itemCd" => p.etims_item_cd,
      "itemClsCd" => codes.item_cls_cd,
      "itemNm" => i.product_name,
      "bcd" => i.barcode,
      "pkgUnitCd" => codes.pkg_unit_cd,
      "pkg" => 1,
      "qtyUnitCd" => codes.qty_unit_cd,
      "qty" => Decimal.to_float(i.quantity),
      "prc" => kes(i.unit_price_cents),
      "splyAmt" => kes(i.line_total_cents),
      "dcRt" => 0.0,
      "dcAmt" => 0.0,
      "taxTyCd" => i.vat_code,
      "taxblAmt" => kes(taxable(i.line_total_cents, i.line_vat_cents, cfg.taxable_basis)),
      "taxAmt" => kes(i.line_vat_cents),
      "totAmt" => kes(i.line_total_cents)
    }
  end

  defp taxable(gross, _tax, :gross), do: gross
  defp taxable(gross, tax, :net), do: gross - tax

  # One code per invoice. For split tender we send the method that paid most.
  # (How KRA wants mixed payments reported is still an open question.)
  defp payment_code(payments) do
    payments |> Enum.max_by(& &1.amount_cents) |> Map.fetch!(:method) |> then(&Map.fetch!(@pmt, &1))
  end

  def kes(cents), do: cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2) |> Decimal.to_float()

  # KRA timestamps are East Africa Time: yyyyMMddHHmmss
  defp eat(%DateTime{} = dt), do: dt |> DateTime.add(3 * 3600, :second) |> Calendar.strftime("%Y%m%d%H%M%S")
end
