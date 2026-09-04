# Live provider smoke tests (`@tag :live`) are opt-in: they require real
# `codex`/`claude` CLIs on PATH and never run in ordinary CI or a plain
# `mix test`. Run them explicitly per provider, e.g.:
#   mix test test/shoestring/harness/capacity/codex_live_smoke_test.exs --include live
# See docs/capacity-fixtures.md for the live-smoke policy.
ExUnit.start(exclude: [:live])
Ecto.Adapters.SQL.Sandbox.mode(Shoestring.Repo, :manual)
