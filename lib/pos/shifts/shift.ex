defmodule Pos.Shifts.Shift do
  use Pos.Schema

  alias Pos.Accounts.User

  @statuses [:open, :pending_approval, :closed]

  schema "shifts" do
    field :device_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :opening_float_cents, :integer, default: 0
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :counted_cash_cents, :integer
    field :expected_cash_cents, :integer
    field :difference_cents, :integer
    field :approved_at, :utc_datetime_usec
    field :close_note, :string
    field :z_report, :map

    belongs_to :user, User
    belongs_to :approved_by, User

    timestamps()
  end

  def open_changeset(shift, attrs) do
    shift
    |> cast(attrs, [:user_id, :device_id, :opening_float_cents, :opened_at])
    |> validate_required([:user_id, :device_id, :opening_float_cents, :opened_at])
    |> validate_number(:opening_float_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id, name: :shifts_one_open_per_user)
    |> unique_constraint(:device_id, name: :shifts_one_open_per_device)
  end
end
