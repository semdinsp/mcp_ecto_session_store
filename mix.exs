defmodule McpEctoSessionStore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/semdinsp/mcp_ecto_session_store"

  def project do
    [
      app: :mcp_ecto_session_store,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:anubis_mcp, "~> 2.0"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0", optional: true},
      # Postgrex's default `:json_library` is Jason; it's an optional dep of
      # postgrex itself, so any app using this store with Postgres already
      # needs it (Phoenix apps pull it in via `phoenix_ecto`/`phoenix` in
      # practice). Required (not optional) only for :test, since the test
      # suite exercises real jsonb inserts against a live database.
      {:jason, "~> 1.0", optional: Mix.env() != :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A Postgres/Ecto-backed Anubis.Server.Session.Store adapter for anubis_mcp,
    for multi-instance Phoenix deployments that don't run Redis.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
