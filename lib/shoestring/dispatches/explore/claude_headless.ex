defmodule Shoestring.Dispatches.Explore.ClaudeHeadless do
  @moduledoc """
  A read-only Claude EXPLORE call through `Shoestring.Harness.ClaudeHeadless.OneShot`,
  run in the private copy of the repository: only the `Read`, `Grep` and
  `Glob` tools, so nothing can be written and no command runs; the safety
  flags sandboxed Claude Elves launch with (no settings files, MCP servers,
  slash commands or saved session, permission prompts denied); and the
  report schema as `--json-schema`.

  UNVERIFIED in a live call; the request it sends was checked offline
  (`plans/evidence/14-coordinator-orchestration/`).
  """
  @behaviour Shoestring.Dispatches.Explore.Adapter

  alias Shoestring.Dispatches.Explore
  alias Shoestring.Harness.ClaudeHeadless.OneShot

  @safety [
    "--safe-mode",
    "--restricted",
    "--setting-sources",
    "",
    "--mcp-config",
    ~s({"mcpServers":{}}),
    "--disable-slash-commands",
    "--permission-mode",
    "dontAsk"
  ]

  @impl true
  def explore(input, opts) do
    OneShot.call(%{
      endpoint: Keyword.get(opts, :endpoint, "claude"),
      model: input["model"],
      schema: input["schema"],
      system_prompt: Explore.system_prompt(),
      prompt: input["prompt"],
      max_output_tokens: input["max_output_tokens"],
      timeout_ms: input["timeout_ms"],
      scratch_prefix: "shoestring-explorer",
      tools: "Read,Grep,Glob",
      workdir: input["workdir"],
      progress: Keyword.get(opts, :progress),
      extra_args: @safety ++ if(input["effort"], do: ["--effort", input["effort"]], else: [])
    })
  end
end
