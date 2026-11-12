defmodule Pos.Etims.Invoice do
  use Pos.Schema

  alias Pos.Sales.Sale

  schema "etims_invoices" do
    field :branch_id, :string
    field :invoice_no, :integer
    field :status, Ecto.Enum, values: [:pending, :accepted], default: :pending
    field :mode, :string, default: "mock"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :receipt_no, :integer
    field :total_receipt_no, :integer
    field :internal_data, :string
    field :receipt_signature, :string
    field :sdc_datetime, :string
    field :sdc_id, :string
    field :request, :map
    field :response, :map
    field :submitted_at, :utc_datetime_usec

    belongs_to :sale, Sale

    timestamps()
  end
end
