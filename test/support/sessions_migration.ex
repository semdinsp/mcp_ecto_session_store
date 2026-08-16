defmodule McpEctoSessionStore.TestRepo.Migrations.CreateSessions do
  @moduledoc false
  # Mirrors the table `mix mcp_ecto_session_store.gen.migration` generates, so
  # the store suite runs against the same schema a consumer installs.
  use Ecto.Migration

  def change do
    create table(:mcp_ecto_sessions, primary_key: false) do
      add(:session_id, :string, primary_key: true, null: false)
      add(:state, :map, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:mcp_ecto_sessions, [:expires_at]))
  end
end
