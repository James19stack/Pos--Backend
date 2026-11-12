defmodule Pos.Audit do
  @moduledoc "Who changed what: prices, costs, stock and receipts. Written in the same transaction as the change."
  import Ecto.Query, warn: false

  alias Pos.Audit.AuditLog
  alias Pos.Repo

  def log(user, action, entity_type, entity_id, changes \\ %{}, repo \\ Repo) do
    repo.insert(%AuditLog{
      user_id: user && user.id,
      action: action,
      entity_type: entity_type,
      entity_id: entity_id && to_string(entity_id),
      changes: changes
    })
  end

  def for_entity(entity_type, entity_id) do
    id = to_string(entity_id)

    Repo.all(
      from l in AuditLog,
        where: l.entity_type == ^entity_type and l.entity_id == ^id,
        order_by: [asc: l.id]
    )
  end
end
