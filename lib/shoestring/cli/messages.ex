defmodule Shoestring.CLI.Messages do
  @moduledoc "One-line refusal messages for `shoestring` commands."

  @doc "The message for a refusal `reason`; `start_hint` says how to start the service."
  def message(reason, start_hint \\ "shoestring start")

  def message({:dirty_worktree, paths}, _),
    do:
      "The repository has uncommitted changes (#{Enum.join(paths, ", ")}). Commit or stash them first."

  def message(:not_a_git_repository, _),
    do: "Not a Git repository. Run it inside one or pass --repo."

  def message(:no_commits, _), do: "The repository has no commits yet."
  def message(:not_a_directory, _), do: "--repo is not a directory."

  def message(:no_gate_detected, _),
    do: "No checks detected. Pass --test PATH (a tracked test file) or --gate mix_test."

  def message({:too_many_python_tests, count}, _),
    do: "#{count} Python test files found; name up to 16 with --test."

  def message({:unknown_gate, name}, _),
    do:
      "Unknown gate #{name}. Use mix_test, mix_precommit, mix_format_check, mix_compile_strict " <>
        "or project:NAME for a gate in config :shoestring, :project_gates."

  def message({:untracked_test_path, path}, _), do: "#{path} is not a tracked file."

  def message({:unsupported_test_path, path}, _),
    do: "#{path} is not a test/**/test_*.py or test/**/*_test.exs file."

  def message(:empty_request, _), do: "Say what you want done."

  def message(:no_default_agent, _),
    do:
      "No default agent. Create one: shoestring agents create NAME --worker claude:MODEL --default"

  def message(:agent_not_found, _), do: "Agent not found. See shoestring agents list."

  def message(:worker_model_required, _),
    do:
      "The agent's Worker role needs an explicit model: shoestring agents set-role NAME Worker claude:MODEL"

  def message(:worker_role_required, _),
    do: "The agent needs a Worker role: shoestring agents set-role NAME Worker claude:MODEL"

  def message(:planner_not_configured, _),
    do:
      "No planner. Give the agent a Claude Coordinator with an explicit model " <>
        "(shoestring agents set-role NAME Coordinator claude:MODEL) or configure :planner."

  def message({:coordinator_cannot_plan, provider}, _),
    do:
      "The agent's Coordinator (#{Shoestring.Harnesses.name(provider)}) cannot draft plans for " <>
        "shoestring do. Give it a Claude Coordinator " <>
        "(shoestring agents set-role NAME Coordinator claude:MODEL) or configure :planner."

  def message(:service_unreachable, start_hint),
    do: "The Shoestring service is not running. Start it in another terminal: #{start_hint}"

  def message(:service_uses_another_database, _),
    do:
      "The running service uses a different state directory than this command. Use the same SHOESTRING_STATE_DIR."

  def message(:service_too_old, _),
    do: "The running service is older than this command. Restart it."

  def message({:service_not_ready, status}, _),
    do: "The service is not ready (HTTP #{status}). See /status."

  def message(:planning_not_confirmed, _),
    do: "Planning not confirmed; nothing was charged. The goal stays recorded."

  def message(:plan_refused, _), do: "The drafted plan was refused and not repaired."

  def message({:planning_failed, state, detail}, _),
    do: "Planning ended without a usable plan (#{state}): #{detail}"

  def message(:database_missing, _),
    do:
      "No Shoestring database in the state directory. Run shoestring init, or set " <>
        "SHOESTRING_STATE_DIR to the service's."

  def message(:database_needs_init, _),
    do:
      "The state database needs an upgrade. Stop the service, then run shoestring init " <>
        "(it backs the database up first)."

  def message(:database_newer, _),
    do: "The state database is newer than this shoestring command. Use the newer release."

  def message(reason, _), do: "Refused: #{inspect(reason, limit: 12)}"
end
