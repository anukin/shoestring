defmodule Shoestring.Harnesses do
  @moduledoc """
  The harnesses Shoestring drives, what each one can do, and which vendor a
  model belongs to. Roles check capabilities here, never harness names, so a
  new harness changes this table rather than the role rules.

  Capabilities:

    * `:coordinate` - an interactive coding CLI a person can chat with.
    * `:converse` - a coordinator session Shoestring drives from code
      (`Shoestring.Harness.Conversation`, iteration 15): read-only in the
      repository and able to reach Shoestring's tools. Codex and opencode
      do not have it yet; opencode's Code Mode can reach the network without
      a permission prompt, so it cannot be held read-only (Phase 0).
    * `:plan` - drafts a plan through Shoestring's tool-free planner call.
    * `:implement` - runs a plan task as a sandboxed Elf.
    * `:review` - reviews a task through Shoestring's tool-free review call.
    * `:explore` - answers a brief from a read-only copy of the repository in
      one call (`Shoestring.Dispatches.Explore`).

  `:converse`, `:plan`, `:implement`, `:review` and `:explore` each name the
  module that provides them, so the table cannot claim a capability without an
  implementation.
  """

  alias Shoestring.Cobbler.{Planner, Review}
  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer, OpencodeAcp}

  @capabilities [:coordinate, :converse, :plan, :implement, :review, :explore]
  @role_capabilities %{
    "Coordinator" => :coordinate,
    "Worker" => :implement,
    "Reviewer" => :review
  }

  # First-party model providers, by the prefix opencode gives them in
  # `provider/model`.
  @vendors %{
    "anthropic" => "anthropic",
    "openai" => "openai",
    "google" => "google",
    "google-vertex" => "google",
    "deepseek" => "deepseek",
    "moonshotai" => "moonshot",
    "zai" => "zhipu",
    "zhipuai" => "zhipu",
    "xai" => "xai",
    "mistral" => "mistral",
    "alibaba" => "alibaba",
    "meta" => "meta"
  }

  defp harnesses do
    %{
      "claude" => %{
        name: "Claude Code",
        coordinate: true,
        converse: ClaudeHeadless.Conversation,
        plan: Planner.ClaudeHeadless,
        implement: ClaudeHeadless,
        review: Review.ClaudeHeadless,
        explore: Shoestring.Dispatches.Explore.ClaudeHeadless
      },
      "codex" => %{
        name: "Codex",
        coordinate: true,
        implement: CodexAppServer,
        review: Review.CodexExec,
        explore: Shoestring.Dispatches.Explore.CodexExec
      },
      "opencode" => %{name: "opencode", coordinate: true, implement: OpencodeAcp}
    }
  end

  @doc "Harness ids, in display order."
  def ids, do: ["claude", "codex", "opencode"]

  @doc "The harness's display name, or the id itself when unknown."
  def name(id), do: get_in(harnesses(), [id, :name]) || id

  @doc "The capabilities `id` has, in the order of `#{inspect(@capabilities)}`."
  def capabilities(id) do
    case Map.get(harnesses(), id) do
      nil -> []
      harness -> Enum.filter(@capabilities, &Map.get(harness, &1))
    end
  end

  def supports?(id, capability), do: capability in capabilities(id)

  @doc "The module providing `capability` for `id`."
  def module(id, capability) when capability in [:converse, :plan, :implement, :review] do
    case get_in(harnesses(), [id, capability]) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc "The capability a role needs, or nil for a team role Shoestring does not run."
  def role_capability(role_name), do: Map.get(@role_capabilities, role_name)

  @doc "Display names of the harnesses with `capability`, joined for a message."
  def offering(capability) do
    case ids() |> Enum.filter(&supports?(&1, capability)) |> Enum.map(&name/1) do
      [] -> "none"
      [only] -> only
      names -> Enum.join(Enum.drop(names, -1), ", ") <> " or " <> List.last(names)
    end
  end

  @doc """
  The vendor whose model `model` is, or nil when it cannot be told. Claude
  Code runs Anthropic models and Codex OpenAI models. An opencode
  `provider/model` (optionally `#variant`) is the provider's vendor when it is
  a first-party one; otherwise, as with opencode's own catalog, OpenRouter or
  Bedrock, it is read from the model's family name.
  """
  def vendor("claude", _model), do: "anthropic"
  def vendor("codex", _model), do: "openai"

  def vendor("opencode", model) when is_binary(model) do
    [id | _] = String.split(model, "#", parts: 2)

    case String.split(id, "/") do
      [prefix, first | _] = segments ->
        Map.get(@vendors, prefix) || Map.get(@vendors, first) || family(List.last(segments))

      _ ->
        nil
    end
  end

  def vendor(_harness, _model), do: nil

  defp family(name) do
    name = String.downcase(name)

    Enum.find_value(
      [
        {~r/(^|[._:-])claude/, "anthropic"},
        {~r/(^|[._:-])(gpt|codex)|^o\d/, "openai"},
        {~r/(^|[._:-])(gemini|gemma)/, "google"},
        {~r/(^|[._:-])deepseek/, "deepseek"},
        {~r/(^|[._:-])kimi/, "moonshot"},
        {~r/(^|[._:-])glm/, "zhipu"},
        {~r/(^|[._:-])(qwen|qwq)/, "alibaba"},
        {~r/(^|[._:-])grok/, "xai"},
        {~r/(^|[._:-])llama/, "meta"},
        {~r/(^|[._:-])(mistral|codestral|devstral|magistral)/, "mistral"},
        {~r/(^|[._:-])nemotron/, "nvidia"},
        {~r/(^|[._:-])minimax/, "minimax"},
        {~r/(^|[._:-])mimo/, "xiaomi"}
      ],
      fn {pattern, vendor} -> if Regex.match?(pattern, name), do: vendor end
    )
  end
end
