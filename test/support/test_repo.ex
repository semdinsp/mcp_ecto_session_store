defmodule McpEctoSessionStore.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :mcp_ecto_session_store, adapter: Ecto.Adapters.Postgres
end
