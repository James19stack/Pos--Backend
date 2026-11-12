# Run with: mix run priv/repo/seeds.exs
# Safe to run more than once. Development data only.
#
# NOTE: VAT classes and barcodes below are illustrative. Verify the tax class
# of each product with KRA/eTIMS rules before going live.

alias Pos.{Accounts, Catalog, Inventory, Repo}
alias Pos.Catalog.{Product, VatRate}

# --- VAT rates (eTIMS tax types: confirm codes against the current KRA spec)
vat_rates =
  for {code, name, bp} <- [
        {"A", "Exempt", 0},
        {"B", "Standard 16%", 1600},
        {"C", "Zero-rated", 0},
        {"D", "Non-VAT", 0},
        {"E", "Reduced 8%", 800}
      ],
      into: %{} do
    rate =
      case Repo.get_by(VatRate, code: code) do
        nil ->
          {:ok, r} = Catalog.create_vat_rate(%{code: code, name: name, rate_bp: bp})
          r

        r ->
          r
      end

    {code, rate}
  end

# --- Users (dev passwords only!)
for {name, email, role} <- [
      {"Admin", "admin@pos.test", :admin},
      {"Manager", "manager@pos.test", :manager},
      {"Supervisor", "supervisor@pos.test", :supervisor},
      {"Cashier", "cashier@pos.test", :cashier}
    ] do
  unless Accounts.get_user_by_email(email) do
    {:ok, _} =
      Accounts.register_user(%{name: name, email: email, password: "password123", role: role})
  end
end

# --- Products: {name, price in KES, vat code, sold by weight?}
products = [
  {"Maize Flour 2kg", 190, "A", false},
  {"Wheat Flour 2kg", 210, "A", false},
  {"Pishori Rice 2kg", 380, "A", false},
  {"Sugar 1kg", 190, "B", false},
  {"Cooking Oil 1L", 330, "B", false},
  {"Salt 500g", 35, "B", false},
  {"Spaghetti 400g", 95, "B", false},
  {"Fresh Milk 500ml", 65, "A", false},
  {"Fresh Milk 1L", 130, "A", false},
  {"White Bread 400g", 65, "C", false},
  {"Brown Bread 400g", 70, "C", false},
  {"Eggs Tray of 30", 540, "A", false},
  {"Tea Leaves 250g", 110, "B", false},
  {"Instant Coffee 100g", 420, "B", false},
  {"Margarine 500g", 250, "B", false},
  {"Butter 250g", 380, "B", false},
  {"Baked Beans 400g", 145, "B", false},
  {"Tomato Paste 70g", 40, "B", false},
  {"Soda 500ml", 60, "B", false},
  {"Soda 2L", 140, "B", false},
  {"Bottled Water 500ml", 40, "B", false},
  {"Bottled Water 1.5L", 90, "B", false},
  {"Fruit Juice 1L", 210, "B", false},
  {"Biscuits 100g", 50, "B", false},
  {"Chocolate Bar 40g", 90, "B", false},
  {"Toothpaste 100g", 180, "B", false},
  {"Toothbrush", 120, "B", false},
  {"Bar Soap 1kg", 250, "B", false},
  {"Laundry Detergent 1kg", 280, "B", false},
  {"Dishwashing Liquid 750ml", 230, "B", false},
  {"Toilet Paper 4 Rolls", 260, "B", false},
  {"Facial Tissue Box", 180, "B", false},
  {"Sanitary Pads 10s", 130, "B", false},
  {"Deodorant 150ml", 250, "B", false},
  {"Body Lotion 400ml", 400, "B", false},
  {"Matchbox", 10, "B", false},
  {"Candle", 20, "B", false},
  {"AA Batteries 4 Pack", 280, "B", false},
  {"Light Bulb LED", 200, "B", false},
  {"A4 Notebook", 120, "B", false},
  {"Blue Pen", 20, "B", false},
  {"Tomatoes (per kg)", 120, "A", true},
  {"Onions (per kg)", 110, "A", true},
  {"Potatoes (per kg)", 100, "A", true},
  {"Carrots (per kg)", 90, "A", true},
  {"Bananas (per kg)", 150, "A", true},
  {"Oranges (per kg)", 160, "A", true},
  {"Sukuma Wiki (per kg)", 60, "A", true},
  {"Beef (per kg)", 700, "A", true},
  {"Cabbage (per kg)", 70, "A", true},
  {"Watermelon (per kg)", 80, "A", true}
]

pad = fn n, width -> n |> Integer.to_string() |> String.pad_leading(width, "0") end

products
|> Enum.with_index(1)
|> Enum.each(fn {{name, price, vat, weighed}, i} ->
  sku = "SKU" <> pad.(i, 4)
  # Fake barcodes (no valid check digit). Weighed items use a "200" prefix.
  barcode = if weighed, do: "200" <> pad.(i, 4), else: "6161100" <> pad.(i, 6)

  unless Repo.get_by(Product, sku: sku) do
    {:ok, product} =
      Catalog.create_product(
        %{
          sku: sku,
          name: name,
          price_cents: price * 100,
          vat_rate_id: vat_rates[vat].id,
          is_weighed: weighed,
          unit: if(weighed, do: "kg", else: "each"),
          reorder_level: if(weighed, do: 10, else: 20)
        },
        [barcode]
      )

    qty = if weighed, do: 50, else: 100
    {:ok, _} = Inventory.adjust_stock(product.id, qty, :opening, note: "Seed opening stock")
  end
end)

IO.puts("Seeded #{length(products)} products. Log in as cashier@pos.test / password123")
