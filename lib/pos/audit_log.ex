defmodule Pos.Audit.AuditLog do
  use Pos.Schema

  alias Pos.Accounts.User

  @primary_key {:id, :id, autogenerate: true}

  schema "audit_logs" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :string
    field :changes, :map

    belongs_to :user, User
    belongs_to :approved_by, User

    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:user_id, :action, :entity_type, :entity_id, :changes, :approved_by_id])
    |> validate_required([:action, :entity_type])
  end
end
