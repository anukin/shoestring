defmodule Shoestring.Coordinator do
  @moduledoc """
  Starting a coordinator: the coding CLI a person chats with, which hands
  tasks to Shoestring (iteration 14 package F).

  `shoestring chat` renders the coordinator's instructions
  (`priv/coordinator/instructions.md` with the session, its grant, the
  agent's roles and instructions) and the command that starts the CLI with
  them. How each CLI receives them (VERIFIED from the request each sends,
  captured locally in its non-interactive mode, 2026-10-26; the interactive
  start is UNVERIFIED; `plans/evidence/14-coordinator-orchestration`):

    * Claude Code 2.1.310: `--model` and `--append-system-prompt-file`.
    * Codex 0.164.0: `-m` and `-c developer_instructions=...` (a TOML literal
      string), which arrives as a developer message.
    * opencode 2.0.31: `OPENCODE_CONFIG_CONTENT` with `model` and
      `instructions`.

  The CLI runs as the person's own session, under its own permission
  prompts; Shoestring does not sandbox it. Its instructions tell it to
  delegate code changes rather than edit the checkout.
  """

  @template "coordinator/instructions.md"

  @doc """
  The coordinator's instructions. `context`: `:session`, `:grant` (or nil),
  `:roles` (`[%{"name", "provider", "model"}]`), `:agent_instructions` and
  `:command` (how to call Shoestring from the coordinator's shell).
  """
  def instructions(context) do
    template = :shoestring |> Application.app_dir("priv") |> Path.join(@template) |> File.read!()

    text =
      template
      |> String.replace("{{command}}", context.command)
      |> String.replace("{{session}}", context.session)
      |> String.replace("{{grant}}", grant_line(context.grant, context.command))
      |> String.replace("{{routing}}", routing(context.roles))

    case context[:agent_instructions] do
      instructions when is_binary(instructions) and instructions != "" ->
        text <> "\n## The person's instructions for this agent\n\n" <> instructions <> "\n"

      _ ->
        text
    end
  end

  @doc """
  The instructions of a coordinator Shoestring drives in its chat screen
  (iteration 15): the same work as `instructions/1`, through the MCP tools
  rather than shell commands. `context`: `:session`, `:grant`, `:roles` and
  `:agent_instructions`.
  """
  def conversation_instructions(context) do
    template =
      :shoestring
      |> Application.app_dir("priv")
      |> Path.join("coordinator/conversation.md")
      |> File.read!()

    text =
      template
      |> String.replace("{{session}}", context.session)
      |> String.replace("{{grant}}", conversation_grant_line(context.grant))
      |> String.replace("{{routing}}", routing(context.roles))

    case context[:agent_instructions] do
      instructions when is_binary(instructions) and instructions != "" ->
        text <> "\n## The person's instructions for this agent\n\n" <> instructions <> "\n"

      _ ->
        text
    end
  end

  defp conversation_grant_line(grant),
    do:
      "Grant `#{grant.id}`: models #{Enum.join(grant.models, ", ")}; purposes " <>
        "#{Enum.join(grant.purposes, ", ")}; up to #{grant.max_dispatches} attempts, " <>
        "#{grant.max_parallel} at once, and #{grant.max_turns} of your turns (each reply " <>
        "to the person or to an inbox message is one)."

  defp grant_line(nil, command),
    do: "No grant yet: every dispatch is refused until the person runs `#{command} grant`."

  defp grant_line(grant, command),
    do:
      "Grant `#{grant.id}`: models #{Enum.join(grant.models, ", ")}; purposes " <>
        "#{Enum.join(grant.purposes, ", ")}; up to #{grant.max_dispatches} attempts, " <>
        "#{grant.max_parallel} at once. `#{command} grants show #{grant.id}` says what is left."

  defp routing(roles) do
    case Enum.reject(roles, &(&1["name"] == "Coordinator")) do
      [] ->
        "The person's agent names no team roles; use the models the grant allows."

      roles ->
        "The person's agent suggests: " <>
          Enum.map_join(roles, "; ", &"#{&1["name"]} #{&1["provider"]}:#{&1["model"]}") <> "."
    end
  end

  @doc """
  The command that starts `provider`'s CLI as the coordinator:
  `%{argv: [...], env: [{name, value}]}`. `instructions` is the rendered text
  and `path` the file it was written to.
  """
  def launch(provider, model, effort, instructions, path, session) do
    env = [{"SHOESTRING_SESSION", session}]

    case provider do
      "claude" ->
        %{
          argv:
            [
              "claude",
              "--model",
              model,
              "--append-system-prompt-file",
              path,
              "--name",
              "Shoestring #{session}"
            ] ++
              if(effort, do: ["--effort", effort], else: []),
          env: env
        }

      "codex" ->
        %{
          argv:
            ["codex", "-m", model, "-c", "developer_instructions=" <> toml_literal(instructions)] ++
              if(effort, do: ["-c", ~s(model_reasoning_effort="#{effort}")], else: []),
          env: env
        }

      "opencode" ->
        %{
          argv: ["opencode"],
          env: [
            {"OPENCODE_CONFIG_CONTENT",
             Jason.encode!(%{"model" => model, "instructions" => [path]})}
            | env
          ]
        }
    end
  end

  # A TOML multi-line literal string takes the text as written; it cannot
  # contain three single quotes, so a run of them is broken up.
  defp toml_literal(text), do: "'''\n" <> String.replace(text, "'''", "' ' '") <> "'''"

  @doc "A POSIX `sh` script that changes to `cwd` and `exec`s the launch."
  def script(%{argv: argv, env: env}, cwd) do
    assignments =
      Enum.map(env, fn {name, value} -> name <> "=" <> Shoestring.Shell.argument(value) end)

    command =
      Enum.join(["env" | assignments] ++ Enum.map(argv, &Shoestring.Shell.argument/1), " ")

    """
    #!/bin/sh
    # Written by shoestring chat: start the coordinator in this terminal.
    rm -f -- "$0"
    cd #{Shoestring.Shell.argument(cwd)} || exit 1
    exec #{command}
    """
  end
end
