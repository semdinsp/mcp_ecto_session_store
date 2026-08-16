if Code.ensure_loaded?(Anubis.Server.Session.Store) and Code.ensure_loaded?(Ecto.Schema) do
  defmodule McpEctoSessionStore do
    @moduledoc """
    Postgres-backed `Anubis.Server.Session.Store` for the Anubis MCP transports.

    ## Why

    Anubis keeps session state in memory and recovers it only on a live
    reconnect *to the node that created it*. On a horizontally-scaled deployment
    (multiple app instances behind a load balancer, no sticky routing), a
    client's follow-up request can land on a node that never saw the session —
    that node's local registry has never heard of it, and Anubis correctly
    404s ("Session not found") rather than silently faking one. A deploy/node
    replacement has the same effect even on a single-instance deployment.

    Persisting the session map lets any node reconstruct a session it didn't
    create, restoring the client's initialized state (client_info + `frame`)
    with no re-initialization required from the client.

    Anubis ships only a Redis adapter; this implements the same behaviour
    against an `Ecto.Repo`, for a Postgres-only deployment that doesn't run
    Redis.

    ## Wiring

        # config/config.exs
        config :anubis_mcp, :session_store,
          enabled: true,
          adapter: McpEctoSessionStore,
          repo: MyApp.Repo,
          ttl: to_timeout(minute: 30)

    The `:repo` may also be set as `config :mcp_ecto_session_store, repo: MyApp.Repo`.
    Run `mix mcp_ecto_session_store.gen.migration --repo MyApp.Repo` to create
    the backing `mcp_ecto_sessions` table.

    ## No process

    The store is stateless: every callback is a direct repo query and the repo
    is already supervised, so `start_link/1` returns `:ignore` instead of
    booting an idle GenServer. Anubis lists the adapter as a child (the
    `{adapter, config}` child-spec form when `enabled: true`); `:ignore` tells
    the supervisor there is nothing to start.

    Postgres has no native key TTL, so expired rows are reaped lazily on
    `load/2` and by `cleanup_expired/1` (call it on a schedule from the host).

    Compile-guarded on `Anubis.Server.Session.Store` and `Ecto.Schema`.

    ## Provenance

    This implementation started from `AttestoMCP.Anubis.SessionStore.Ecto`
    (https://github.com/XukuLLC/attesto_mcp, MIT-licensed), adapted as a
    standalone package because `attesto_mcp` itself requires `anubis_mcp < 2.0`
    and can't be added as a dependency by an app on `anubis_mcp ~> 2.0`. Logic
    is unchanged from the original; only module names/table name differ.
    """

    @behaviour Anubis.Server.Session.Store

    import Ecto.Query

    alias Anubis.Server.Session.Store
    alias McpEctoSessionStore.JSONSafe
    alias McpEctoSessionStore.Session

    require Logger

    @app :anubis_mcp

    # Matches the Anubis Redis adapter default: 30 minutes, in milliseconds.
    @default_ttl_ms 1_800_000

    # Anubis adds the configured store as `{adapter, config}`, so the adapter must
    # expose `child_spec/1`. `start_link/1` returns `:ignore`: the store is
    # stateless and rides on the already-supervised host repo.
    @doc false
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    @impl Store
    def start_link(_opts) do
      # Resolve the repo at boot so a misconfiguration fails fast here rather
      # than surfacing as a save that silently errors and a load that crashes a
      # reconnect. The store itself starts no process (it rides the host repo).
      resolved_repo = repo()
      Logger.info("McpEctoSessionStore starting: repo=#{inspect(resolved_repo)}")
      :ignore
    end

    @impl Store
    def save(session_id, state, opts) do
      Logger.info("McpEctoSessionStore.save/3 called: session_id=#{inspect(session_id)}")

      now = DateTime.utc_now()
      expires_at = DateTime.add(now, ttl_ms(opts), :millisecond)

      # Anubis folds the whole request `conn.assigns` into the persisted frame,
      # so `state` can carry values with no `JSON.Encoder` impl. Strip anything
      # non-encodable before the jsonb insert so the driver does not raise
      # mid-`initialize` and kill the session process.
      state = JSONSafe.sanitize(state)

      %Session{}
      |> Session.changeset(%{session_id: session_id, state: state, expires_at: expires_at})
      |> repo().insert(
        conflict_target: :session_id,
        on_conflict: {:replace, [:state, :expires_at, :updated_at]}
      )
      |> case do
        {:ok, _session} ->
          Logger.info("McpEctoSessionStore.save/3 succeeded: session_id=#{inspect(session_id)}")
          :ok

        {:error, changeset} ->
          Logger.error(
            "McpEctoSessionStore.save/3 changeset error: session_id=#{inspect(session_id)} errors=#{inspect(changeset.errors)}"
          )

          {:error, changeset}
      end
    rescue
      # The sanitizer above should make the insert encodable, but Anubis only
      # logs-and-continues on `{:error, _}` while the session process dies on a
      # raise. A bare rescue is intentional: persisting a session must never take
      # down the connection, whatever the driver/Ecto raises.
      exception ->
        Logger.error("MCP session persist failed for #{inspect(session_id)}: #{inspect(exception)}")
        {:error, exception}
    end

    @impl Store
    def load(session_id, _opts) do
      Logger.info("McpEctoSessionStore.load/2 called: session_id=#{inspect(session_id)}")

      now = DateTime.utc_now()

      case repo().get(Session, session_id) do
        nil ->
          Logger.info("McpEctoSessionStore.load/2 not found: session_id=#{inspect(session_id)}")
          {:error, :not_found}

        %Session{expires_at: expires_at, state: state} ->
          if DateTime.after?(expires_at, now) do
            Logger.info("McpEctoSessionStore.load/2 restored: session_id=#{inspect(session_id)}")
            {:ok, state}
          else
            Logger.info(
              "McpEctoSessionStore.load/2 found but expired, reaping: session_id=#{inspect(session_id)} expires_at=#{expires_at}"
            )

            # Reap, but only while still expired: guarding on `expires_at <= now`
            # means a row a concurrent `save/3` refreshed with a future expiry is
            # NOT deleted by this read path.
            repo().delete_all(from(s in Session, where: s.session_id == ^session_id and s.expires_at <= ^now))
            {:error, :not_found}
          end
      end
    end

    @impl Store
    def delete(session_id, _opts) do
      repo().delete_all(from(s in Session, where: s.session_id == ^session_id))
      :ok
    end

    @impl Store
    def list_active(_opts) do
      now = DateTime.utc_now()
      {:ok, repo().all(from(s in Session, where: s.expires_at > ^now, select: s.session_id))}
    end

    @impl Store
    def update_ttl(session_id, ttl_ms, _opts) when is_integer(ttl_ms) and ttl_ms > 0 do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, ttl_ms, :millisecond)

      # Guard on unexpired so a not-yet-reaped expired row cannot be revived
      # (Redis would have already dropped the key).
      case repo().update_all(
             from(s in Session, where: s.session_id == ^session_id and s.expires_at > ^now),
             set: [expires_at: expires_at, updated_at: now]
           ) do
        {0, _} -> {:error, :not_found}
        {_count, _} -> :ok
      end
    end

    @impl Store
    def update(session_id, updates, opts) when is_map(updates) do
      # Read-modify-write under a row lock so concurrent updates of the same
      # session cannot lose each other (this stateless adapter has no serializing
      # GenServer). Only an unexpired row is updated.
      case repo().transaction(fn -> locked_update(session_id, updates, opts) end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp locked_update(session_id, updates, opts) do
      now = DateTime.utc_now()
      query = from(s in Session, where: s.session_id == ^session_id and s.expires_at > ^now, lock: "FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:not_found)
        %Session{state: state} -> merge_and_save(session_id, state, updates, opts)
      end
    end

    defp merge_and_save(session_id, state, updates, opts) do
      case save(session_id, Map.merge(state || %{}, stringify_keys(updates)), opts) do
        :ok -> :ok
        {:error, reason} -> repo().rollback(reason)
      end
    end

    @impl Store
    def cleanup_expired(_opts) do
      now = DateTime.utc_now()
      {count, _} = repo().delete_all(from(s in Session, where: s.expires_at <= ^now))
      {:ok, count}
    end

    # ----- internal -----

    defp ttl_ms(opts), do: Keyword.get(opts, :ttl) || config_ttl_ms()

    defp config_ttl_ms do
      @app |> Application.get_env(:session_store, []) |> Keyword.get(:ttl, @default_ttl_ms)
    end

    # Anubis persists string-keyed JSON; keep merge keys as strings so a later
    # round-trip does not yield a mixed atom/string-keyed map.
    defp stringify_keys(map) do
      Map.new(map, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end

    defp repo do
      config_repo = @app |> Application.get_env(:session_store, []) |> Keyword.get(:repo)

      case config_repo || Application.get_env(:mcp_ecto_session_store, :repo) do
        nil ->
          raise ArgumentError,
                "McpEctoSessionStore: no repo configured. Set " <>
                  "`config :anubis_mcp, :session_store, repo: MyApp.Repo` (or " <>
                  "`config :mcp_ecto_session_store, repo: MyApp.Repo`)."

        repo ->
          repo
      end
    end
  end
end
