defmodule Pos.Sales do
  @moduledoc """
  Creating sales. The server is the authority on prices, VAT and totals:
  the client only says WHICH barcodes, HOW MANY, and HOW the customer paid.

  Input (string or atom keys):

      %{
        "id" => "client-generated UUID",
        "device_id" => "till-1",
        "sold_at" => "2026-11-02T08:30:00Z",          # optional
        "items" => [%{"barcode" => "616...", "quantity" => 2}],
        "payments" => [%{"method" => "cash", "amount_cents" => 23200, "tendered_cents" => 25000}]
      }

  Money rules: integer cents, prices are VAT-inclusive, so
  subtotal_cents = sum of line totals, vat_cents = VAT contained in that total.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Pos.Accounts.User
  alias Pos.{Catalog, Inventory, Repo}
  alias Pos.Payments.{C2B, Mpesa}
  alias Pos.Etims
  alias Pos.Shifts
  alias Pos.Sales.Sale

  def get_sale(id) do
    Sale |> Repo.get(id) |> Repo.preload([:items, :payments])
  end

  @doc "Finds a sale by the number printed on its receipt (for returns)."
  def get_sale_by_receipt(receipt_no) when is_binary(receipt_no) do
    Sale |> Repo.get_by(receipt_no: receipt_no |> String.trim() |> String.upcase()) |> Repo.preload([:items, :payments])
  end

  def get_sale_by_receipt(_), do: nil

  @doc "Sales flagged for manager review (e.g. stock went negative)."
  def list_sales_needing_review do
    from(s in Sale,
      where: s.needs_review == true,
      order_by: [desc: s.sold_at],
      preload: [:items, :payments]
    )
    |> Repo.all()
  end

  @doc """
  Idempotent: sending the same sale id again returns the original sale and
  changes nothing. This is what makes offline sync and retries safe.
  """
  def create_sale(attrs, %User{} = cashier) when is_map(attrs) do
    with {:ok, id} <- parse_id(attrs) do
      case get_sale(id) do
        %Sale{} = existing -> {:ok, existing}
        nil -> build_and_insert(id, attrs, cashier)
      end
    end
  end

  @doc "Change to hand back on cash payments."
  def change_due_cents(%Sale{payments: payments}) do
    payments
    |> Enum.filter(&(&1.method == :cash))
    |> Enum.reduce(0, fn p, acc ->
      acc + max((p.tendered_cents || p.amount_cents) - p.amount_cents, 0)
    end)
  end

  ## Building the sale

  defp build_and_insert(id, attrs, cashier) do
    with {:ok, shift} <- Shifts.fetch_open(cashier),
         {:ok, lines} <- build_lines(fetch(attrs, "items")),
         totals = compute_totals(lines),
         {:ok, payments} <- build_payments(fetch(attrs, "payments"), totals.total_cents, id),
         {:ok, sold_at} <- parse_sold_at(fetch(attrs, "sold_at")) do
      sale_attrs =
        Map.merge(totals, %{
          id: id,
          cashier_id: cashier.id,
          shift_id: shift.id,
          device_id: fetch(attrs, "device_id"),
          receipt_no: receipt_no(id),
          status: :completed,
          sold_at: sold_at,
          items: Enum.map(lines, &item_attrs/1),
          payments: payments
        })

      insert_sale(id, sale_attrs, lines, cashier)
    end
  end

  defp insert_sale(id, sale_attrs, lines, cashier) do
    Multi.new()
    # Locks the shift for the length of this sale, so a cash-up cannot slip in between
    |> Multi.run(:shift, fn repo, _ -> Shifts.lock_open(repo, sale_attrs.shift_id) end)
    |> Multi.insert(:sale, Sale.changeset(%Sale{}, sale_attrs))
    |> Multi.run(:mpesa, fn repo, %{sale: sale} -> claim_mpesa(repo, sale.id, sale_attrs.payments) end)
    |> Multi.run(:stock, fn repo, %{sale: sale} -> deduct_stock(repo, sale, lines, cashier) end)
    |> Multi.run(:review, fn repo, %{sale: sale, stock: quantities} ->
      flag_if_negative(repo, sale, quantities)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{review: sale}} ->
        sale = Repo.preload(sale, [:items, :payments])
        # After the commit, so a KRA problem can never block or undo a sale
        Etims.enqueue(sale)
        {:ok, sale}

      # Two identical requests raced: the other one won, return its sale.
      {:error, :sale, %Ecto.Changeset{errors: errors} = changeset, _} ->
        if Keyword.has_key?(errors, :id) and get_sale(id) do
          {:ok, get_sale(id)}
        else
          {:error, changeset}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # An M-Pesa payment can pay for exactly one sale: the claim locks the request row.
  defp claim_mpesa(repo, sale_id, payments) do
    payments
    |> Enum.filter(&(&1.method == :mpesa))
    |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
      result =
        if Map.has_key?(p, :mpesa_c2b_id),
          do: C2B.claim(repo, p.mpesa_c2b_id, sale_id),
          else: Mpesa.claim(repo, p.mpesa_request_id)

      case result do
        {:ok, request} -> {:cont, {:ok, [request | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp deduct_stock(repo, sale, lines, cashier) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      attrs = %{
        product_id: line.product.id,
        quantity: Decimal.negate(line.quantity),
        reason: :sale,
        reference_type: "sale",
        reference_id: sale.id,
        user_id: cashier.id
      }

      case Inventory.apply_movement(repo, attrs) do
        {:ok, %{quantity: new_qty}} -> {:cont, {:ok, [new_qty | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # Never block a sale at the till because the system thinks stock is zero:
  # the shelf is the truth. Flag it for a manager instead.
  defp flag_if_negative(repo, sale, quantities) do
    if Enum.any?(quantities, &Decimal.lt?(&1, 0)) do
      sale |> Ecto.Changeset.change(needs_review: true) |> repo.update()
    else
      {:ok, sale}
    end
  end

  ## Lines

  defp build_lines(items) when is_list(items) and items != [], do: map_while_ok(items, &build_line/1)
  defp build_lines(_), do: {:error, :no_items}

  defp build_line(item) do
    code = fetch(item, "barcode")

    with {:ok, qty} <- parse_quantity(fetch(item, "quantity")),
         {:ok, product} <- find_product(code),
         :ok <- check_quantity_for(product, qty) do
      line_total =
        qty
        |> Decimal.mult(Decimal.new(product.price_cents))
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()

      rate_bp = product.vat_rate.rate_bp

      {:ok,
       %{
         product: product,
         barcode: String.trim(code),
         quantity: qty,
         unit_price_cents: product.price_cents,
         vat_rate_bp: rate_bp,
         vat_code: product.vat_rate.code,
         line_total_cents: line_total,
         # VAT contained in a VAT-inclusive price
         line_vat_cents: round_div(line_total * rate_bp, 10_000 + rate_bp)
       }}
    end
  end

  defp find_product(code) do
    case Catalog.get_product_by_barcode(code) do
      nil -> {:error, {:unknown_barcode, code}}
      product -> {:ok, product}
    end
  end

  defp check_quantity_for(product, qty) do
    if product.is_weighed or Decimal.eq?(Decimal.round(qty, 0), qty) do
      :ok
    else
      {:error, :fractional_quantity}
    end
  end

  defp item_attrs(line) do
    %{
      product_id: line.product.id,
      product_name: line.product.name,
      barcode: line.barcode,
      quantity: line.quantity,
      unit_price_cents: line.unit_price_cents,
      vat_rate_bp: line.vat_rate_bp,
      vat_code: line.vat_code,
      line_total_cents: line.line_total_cents,
      line_vat_cents: line.line_vat_cents
    }
  end

  defp compute_totals(lines) do
    subtotal = lines |> Enum.map(& &1.line_total_cents) |> Enum.sum()
    vat = lines |> Enum.map(& &1.line_vat_cents) |> Enum.sum()

    # Discounts arrive with the Promotions context; none for now.
    %{subtotal_cents: subtotal, discount_cents: 0, vat_cents: vat, total_cents: subtotal}
  end

  ## Payments

  defp build_payments(payments, total, sale_id) when is_list(payments) and payments != [] do
    with {:ok, built} <- map_while_ok(payments, &build_payment(&1, sale_id)),
         :ok <- check_payment_total(built, total) do
      {:ok, built}
    end
  end

  defp build_payments(_, _, _), do: {:error, :no_payments}

  defp build_payment(p, sale_id) do
    with {:ok, method} <- parse_method(fetch(p, "method")),
         {:ok, amount} <- parse_amount(fetch(p, "amount_cents")),
         {:ok, tendered} <- parse_tendered(method, fetch(p, "tendered_cents"), amount),
         {:ok, reference} <- parse_reference(method, fetch(p, "reference")),
         {:ok, extra} <- mpesa_details(method, sale_id, amount, p) do
      {:ok,
       Map.merge(
         %{
           method: method,
           status: :confirmed,
           amount_cents: amount,
           tendered_cents: tendered,
           reference: reference
         },
         extra
       )}
    end
  end

  # An M-Pesa payment must point at a request that is already confirmed for THIS sale.
  defp mpesa_details(:mpesa, sale_id, amount, p) do
    case fetch(p, "mpesa_trans_id") do
      nil -> stk_details(sale_id, amount, fetch(p, "mpesa_request_id"))
      trans_id -> c2b_details(amount, trans_id)
    end
  end

  defp mpesa_details(_method, _sale_id, _amount, _p), do: {:ok, %{}}

  defp stk_details(sale_id, amount, request_id) do
    with {:ok, request} <- Mpesa.fetch_claimable(sale_id, request_id, amount) do
      {:ok,
       %{
         # The query API returns no receipt number, so fall back to the checkout id.
         reference: request.receipt_number || request.checkout_request_id,
         checkout_request_id: request.checkout_request_id,
         phone: request.phone,
         mpesa_request_id: request.id
       }}
    end
  end

  # The customer paid the till/paybill themselves; Safaricom's notification is the proof.
  defp c2b_details(amount, trans_id) do
    with {:ok, payment} <- C2B.fetch_claimable(trans_id, amount) do
      {:ok, %{reference: payment.trans_id, mpesa_c2b_id: payment.id}}
    end
  end

  defp check_payment_total(payments, total) do
    received = payments |> Enum.map(& &1.amount_cents) |> Enum.sum()

    if received == total do
      :ok
    else
      {:error, {:payment_mismatch, %{expected_cents: total, received_cents: received}}}
    end
  end

  defp parse_method(m) when m in [:cash, "cash"], do: {:ok, :cash}
  defp parse_method(m) when m in [:card, "card"], do: {:ok, :card}
  # M-Pesa is confirmed beforehand through Pos.Payments.Mpesa; here it is only claimed.
  defp parse_method(m) when m in [:mpesa, "mpesa"], do: {:ok, :mpesa}
  defp parse_method(_), do: {:error, :invalid_payment_method}

  defp parse_amount(a) when is_integer(a) and a > 0, do: {:ok, a}
  defp parse_amount(_), do: {:error, :invalid_amount}

  defp parse_tendered(:cash, nil, amount), do: {:ok, amount}
  defp parse_tendered(:cash, t, amount) when is_integer(t) and t >= amount, do: {:ok, t}
  defp parse_tendered(:cash, t, _amount) when is_integer(t), do: {:error, :insufficient_tender}
  defp parse_tendered(:cash, _, _), do: {:error, :invalid_amount}
  defp parse_tendered(_method, _, _), do: {:ok, nil}

  defp parse_reference(:card, ref) when is_binary(ref) and ref != "", do: {:ok, ref}
  defp parse_reference(:card, _), do: {:error, :card_reference_required}
  defp parse_reference(_method, ref), do: {:ok, ref}

  ## Parsing helpers

  defp parse_id(attrs) do
    with id when is_binary(id) <- fetch(attrs, "id"),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, uuid}
    else
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_sold_at(nil), do: {:ok, DateTime.utc_now()}
  defp parse_sold_at(%DateTime{} = dt), do: {:ok, dt}

  defp parse_sold_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_sold_at}
    end
  end

  defp parse_sold_at(_), do: {:error, :invalid_sold_at}

  defp parse_quantity(q) when is_integer(q), do: positive(Decimal.new(q))
  defp parse_quantity(q) when is_float(q), do: positive(Decimal.from_float(q))
  defp parse_quantity(%Decimal{} = q), do: positive(q)

  defp parse_quantity(q) when is_binary(q) do
    case Decimal.parse(q) do
      {d, ""} -> positive(d)
      _ -> {:error, :invalid_quantity}
    end
  end

  defp parse_quantity(_), do: {:error, :invalid_quantity}

  defp positive(d) do
    d = Decimal.round(d, 3)
    if Decimal.gt?(d, 0), do: {:ok, d}, else: {:error, :invalid_quantity}
  end

  # Integer division rounded half up (non-negative inputs).
  defp round_div(n, d), do: div(2 * n + d, 2 * d)

  # Short, human-friendly placeholder. Replace with a per-store sequence
  # before eTIMS, which needs sequential invoice numbers.
  defp receipt_no(id), do: "R" <> String.upcase(binary_part(id, 0, 8))

  defp map_while_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn el, {:ok, acc} ->
      case fun.(el) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # Accepts string or atom keys. Keys are fixed names from this module, never user input.
  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch(_, _), do: nil
end
