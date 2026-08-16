# McpEctoSessionStore

A Postgres-backed [`Anubis.Server.Session.Store`](https://hexdocs.pm/anubis_mcp/Anubis.Server.Session.Store.html)
adapter for [`anubis_mcp`](https://hex.pm/packages/anubis_mcp), for
multi-instance Phoenix deployments that don't run Redis.

## Why

`anubis_mcp`'s default session registry is per-node: an MCP session created
via `initialize` on one instance is invisible to any other. On a
horizontally-scaled deployment (e.g. two or more Fly.io machines behind a
load balancer with no sticky routing), a client's follow-up request can land
on a node that never saw the session — that node correctly responds
`404 Session not found` rather than silently faking one. A deploy/node
replacement has the same effect even on a single-instance deployment.

`anubis_mcp` ships a Redis-backed store for exactly this case. This library
is the same idea for apps that already run Postgres and don't want to stand
up Redis just for MCP session state.

## Installation

```elixir
def deps do
  [
    {:mcp_ecto_session_store, "~> 0.1"}
  ]
end
```

## Setup

1. Generate the migration for your app's repo:

   ```
   mix mcp_ecto_session_store.gen.migration --repo MyApp.Repo
   ```

   Run it: `mix ecto.migrate`.

2. Configure the adapter:

   ```elixir
   config :anubis_mcp, :session_store,
     enabled: true,
     adapter: McpEctoSessionStore,
     ttl: to_timeout(minute: 30)  # matches anubis_mcp's own Redis-adapter default

   config :mcp_ecto_session_store, repo: MyApp.Repo
   ```

That's it — `anubis_mcp` calls this module directly per the
`Anubis.Server.Session.Store` behaviour. There's no process to add to your
supervision tree; every callback is a plain, synchronous `Repo` operation.

## Cleaning up expired sessions

Postgres has no native key TTL. Expired rows are reaped lazily whenever
`load/2` encounters one, but for apps with sessions that are created and
never revisited, schedule a periodic sweep (e.g. via
[Oban](https://hex.pm/packages/oban), a cron job, or a `GenServer` timer):

```elixir
McpEctoSessionStore.cleanup_expired([])
```

## Provenance

This library started from
[`AttestoMCP.Anubis.SessionStore.Ecto`](https://github.com/XukuLLC/attesto_mcp)
(MIT-licensed, © Neil Berkman), adapted as a standalone package because
`attesto_mcp` itself requires `anubis_mcp < 2.0` and can't be added as a
dependency by an app already on `anubis_mcp ~> 2.0`'s streamable-HTTP-only
API. Logic is unchanged from the original — module names and the backing
table name differ so it can coexist with `attesto_mcp` if an app ever adds
that too. See `LICENSE` for full attribution.

If you don't have `anubis_mcp`'s version constraint and want the fuller
Attesto OAuth/DPoP/mTLS ecosystem (auth, not just session persistence),
[`attesto_mcp`](https://hex.pm/packages/attesto_mcp) is worth a look —
this library only exists to fill the gap for apps that can't take that
dependency.

## License

MIT. See `LICENSE`.
