defmodule Shoestring.Cobbler.Review.ClaudeHeadless do
  @moduledoc """
  A tool-free Claude review through `Shoestring.Harness.ClaudeHeadless.OneShot`
  (the planner's reviewed call): no tools, no MCP servers, no session, an
  empty working directory, the findings schema as `--json-schema` and the
  packet as the prompt.
  """
  @behaviour Shoestring.Cobbler.Review.Adapter

  alias Shoestring.Cobbler.Review.Adapter
  alias Shoestring.Harness.ClaudeHeadless.OneShot

  @impl true
  def review(input, opts) do
    OneShot.call(%{
      endpoint: Keyword.get(opts, :endpoint, "claude"),
      model: input["model"],
      schema: input["schema"],
      system_prompt: Adapter.system_prompt(),
      prompt: input["packet_json"],
      max_output_tokens: input["max_output_tokens"],
      timeout_ms: input["timeout_ms"],
      scratch_prefix: "shoestring-reviewer"
    })
  end
end
