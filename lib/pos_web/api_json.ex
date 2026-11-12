defmodule PosWeb.ApiJSON do
  @moduledoc "Turns structs into the JSON shapes documented in PosWeb.Schemas."

  def user(u), do: %{id: u.id, name: u.name, email: u.email, role: u.role}

  def product(p) do
    %{
      id: p.id,
      sku: p.sku,
      name: p.name,
      price_cents: p.price_cents,
      is_weighed: p.is_weighed,
      unit: p.unit,
      vat_code: p.vat_rate.code,
      vat_rate_bp: p.vat_rate.rate_bp,
      barcodes: Enum.map(p.barcodes, & &1.code)
    }
  end

  @doc "Decimal as plain text without trailing zeros: 7.000 -> \"7\""
  def dec(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  def product_admin(p) do
    %{
      id: p.id,
      sku: p.sku,
      name: p.name,
      price_cents: p.price_cents,
      cost_cents: p.cost_cents,
      is_weighed: p.is_weighed,
      unit: p.unit,
      reorder_level: dec(p.reorder_level),
      active: p.active,
      vat_code: p.vat_rate.code,
      vat_rate_bp: p.vat_rate.rate_bp,
      barcodes: Enum.map(p.barcodes, & &1.code),
      etims_item_cls_cd: p.etims_item_cls_cd,
      pkg_unit_cd: p.pkg_unit_cd,
      qty_unit_cd: p.qty_unit_cd,
      etims_registered: p.etims_registered_at != nil,
      category_id: p.category_id,
      category: category_name(p),
      stock_quantity: stock_quantity(p)
    }
  end

  defp stock_quantity(%{stock_level: %Pos.Inventory.StockLevel{quantity: q}}), do: dec(q)
  defp stock_quantity(_), do: nil

  defp category_name(%{category: %Pos.Catalog.Category{name: name}}), do: name
  defp category_name(_), do: nil

  def category(c) do
    %{id: c.id, name: c.name, etims_item_cls_cd: c.etims_item_cls_cd, pkg_unit_cd: c.pkg_unit_cd, qty_unit_cd: c.qty_unit_cd}
  end

  def return(r) do
    %{
      id: r.id,
      sale_id: r.sale_id,
      reason: r.reason,
      refund_method: r.refund_method,
      refund_cents: r.refund_cents,
      refund_vat_cents: r.refund_vat_cents,
      approved_by_id: r.approved_by_id,
      created_at: r.inserted_at,
      items: Enum.map(r.items, &%{sale_item_id: &1.sale_item_id, quantity: dec(&1.quantity), refund_cents: &1.refund_cents})
    }
  end

  def sale_for_return(sale, remaining) do
    sale(sale)
    |> Map.put(:returnable, Enum.map(sale.items, &%{sale_item_id: &1.id, barcode: &1.barcode, product_name: &1.product_name, remaining: dec(remaining[&1.id])}))
  end

  def etims(i) do
    %{
      id: i.id,
      sale_id: i.sale_id,
      invoice_no: i.invoice_no,
      status: i.status,
      attempts: i.attempts,
      last_error: i.last_error,
      receipt_no: i.receipt_no,
      internal_data: i.internal_data,
      receipt_signature: i.receipt_signature,
      sdc_datetime: i.sdc_datetime,
      # true while the mock stands in for KRA: receipts must say TEST MODE
      mock: i.mode == "mock"
    }
  end

  def movement(m) do
    %{
      id: m.id,
      quantity: dec(m.quantity),
      reason: m.reason,
      note: m.note,
      user_id: m.user_id,
      reference_type: m.reference_type,
      reference_id: m.reference_id,
      inserted_at: m.inserted_at
    }
  end

  def goods_receipt(r) do
    %{
      id: r.id,
      supplier_name: r.supplier_name,
      reference: r.reference,
      note: r.note,
      received_at: r.received_at,
      items:
        Enum.map(r.items, fn i ->
          %{product_id: i.product_id, quantity: dec(i.quantity), unit_cost_cents: i.unit_cost_cents}
        end)
    }
  end

  def shift(s) do
    %{
      id: s.id,
      user_id: s.user_id,
      device_id: s.device_id,
      status: s.status,
      opening_float_cents: s.opening_float_cents,
      opened_at: s.opened_at,
      closed_at: s.closed_at,
      counted_cash_cents: s.counted_cash_cents,
      expected_cash_cents: s.expected_cash_cents,
      difference_cents: s.difference_cents,
      approved_by_id: s.approved_by_id,
      close_note: s.close_note,
      z_report: s.z_report
    }
  end

  def c2b_payment(p) do
    %{
      trans_id: p.trans_id,
      amount_cents: p.amount_cents,
      payer_name: p.payer_name,
      paid_at: p.paid_at,
      transaction_type: p.transaction_type,
      bill_ref_number: p.bill_ref_number,
      claimed: p.claimed_at != nil
    }
  end

  def mpesa_request(r) do
    %{
      id: r.id,
      sale_id: r.sale_id,
      amount_cents: r.amount_cents,
      phone: r.phone,
      status: r.status,
      receipt_number: r.receipt_number,
      result_code: r.result_code,
      result_desc: r.result_desc,
      paid_at: r.paid_at,
      claimed: r.claimed_at != nil
    }
  end

  def sale(s) do
    %{
      id: s.id,
      receipt_no: s.receipt_no,
      status: s.status,
      cashier_id: s.cashier_id,
      device_id: s.device_id,
      sold_at: s.sold_at,
      subtotal_cents: s.subtotal_cents,
      discount_cents: s.discount_cents,
      vat_cents: s.vat_cents,
      total_cents: s.total_cents,
      change_due_cents: Pos.Sales.change_due_cents(s),
      needs_review: s.needs_review,
      etims_status: s.etims_status,
      items: Enum.map(s.items, &item/1),
      payments: Enum.map(s.payments, &payment/1)
    }
  end

  defp item(i) do
    %{
      id: i.id,
      product_id: i.product_id,
      product_name: i.product_name,
      barcode: i.barcode,
      quantity: Decimal.to_string(i.quantity, :normal),
      unit_price_cents: i.unit_price_cents,
      vat_rate_bp: i.vat_rate_bp,
      vat_code: i.vat_code,
      line_total_cents: i.line_total_cents,
      line_vat_cents: i.line_vat_cents
    }
  end

  defp payment(p) do
    %{
      id: p.id,
      method: p.method,
      status: p.status,
      amount_cents: p.amount_cents,
      tendered_cents: p.tendered_cents,
      reference: p.reference
    }
  end
end
