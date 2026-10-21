defmodule Shoestring.Terminal.Launch do
  @moduledoc "Server-owned interactive launch profiles; browser messages never supply argv, cwd or environment."

  alias Shoestring.Harness.ClaudeHeadless.Sandbox

  def helper do
    configured = Application.get_env(:shoestring, :terminal_helper)
    packaged = Application.app_dir(:shoestring, "priv/bin/shoestring-terminal")
    path = configured || packaged
    if File.regular?(path), do: {:ok, Path.expand(path)}, else: {:error, :terminal_helper_missing}
  end

  def profile(provider, request, workdir) do
    with {:ok, %{} = _policy} <-
           Shoestring.Harness.CodexAppServer.GitSandbox.policy(workdir, request.workspace_ref),
         {:ok, executable, args, extra_env} <- command(provider, request, workdir),
         executable when is_binary(executable) <- System.find_executable(executable) do
      # Claude's macOS credential lookup needs USER even when HOME is set.
      # Preserve that identity without inheriting credential variables.
      env =
        ~w(PATH HOME USER TMPDIR LANG LC_ALL LC_CTYPE)
        |> Enum.flat_map(fn name ->
          case System.get_env(name) do
            nil -> []
            value -> [{name, value}]
          end
        end)
        |> Map.new()
        |> Map.merge(Map.new(Sandbox.git_env()))
        |> Map.merge(Map.new(extra_env))
        |> Map.merge(%{"TERM" => "xterm-256color", "COLORTERM" => "truecolor"})

      {:ok, %{executable: executable, argv: args, cwd: workdir, env: env}}
    else
      {:ok, nil} -> {:error, :private_terminal_worktree_required}
      nil -> {:error, :terminal_executable_missing}
      {:error, _} = error -> error
    end
  end

  defp command("fixture", _request, _workdir) do
    {:ok, "python3", ["-B", Application.app_dir(:shoestring, "priv/terminal/fixture.py")], []}
  end

  defp command("claude", request, workdir) do
    with {:ok, sandbox} <- Sandbox.prepare(workdir, request.workspace_ref) do
      {:ok, "claude", interactive_options(sandbox.options) ++ [request.prompt], sandbox.env}
    end
  end

  defp command("codex", request, _workdir) do
    {:ok, "codex",
     ["--sandbox", "workspace-write", "--ask-for-approval", "on-request", request.prompt], []}
  end

  defp command(_provider, _request, _workdir), do: {:error, :unsupported_terminal_provider}

  # The CLI documents these two options as print-only. Keep the sandbox and
  # customization restrictions, but let the interactive TUI ask the human.
  defp interactive_options([]), do: []
  defp interactive_options(["--no-session-persistence" | rest]), do: interactive_options(rest)

  defp interactive_options(["--permission-prompts", _target | rest]),
    do: interactive_options(rest)

  defp interactive_options(["--permission-mode", _mode | rest]),
    do: ["--permission-mode", "manual" | interactive_options(rest)]

  defp interactive_options([option | rest]), do: [option | interactive_options(rest)]
end
