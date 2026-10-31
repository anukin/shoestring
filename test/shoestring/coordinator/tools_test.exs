defmodule Shoestring.Coordinator.ToolsTest do
  @moduledoc """
  The coordinator's MCP tools against a real temporary Git repository, a
  grant made the way a person makes one, and Oban in manual testing mode:
  each tool's data must be the JSON its iteration 14 command prints, and a
  token's session must be the only one it can act for. No service, provider
  or network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.{Advice, Capacity, Dispatch, Grant, Runs}
  alias Shoestring.CLI.Refusal
  alias Shoestring.Coordinator.Tools

  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-tools-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    on_exit(fn -> File.rm_rf!(repo) end)
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])

    brief = Path.join(System.tmp_dir!(), "shoestring-tools-brief-#{Ecto.UUID.generate()}.md")
    on_exit(fn -> File.rm(brief) end)
    File.write!(brief, @brief)
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    %{repo: repo, brief: brief, binding: %{session_id: "s1", repository: repo}}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp context(ctx, opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: ctx.repo,
      service: fn -> :ok end,
      start_hint: "mix phx.server",
      interactive?: fn -> Keyword.get(opts, :interactive, false) end,
      env: fn "SHOESTRING_SESSION" -> Keyword.get(opts, :session, "s1") end
    }
  end

  # What the command printed on stdout, decoded.
  defp printed! do
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  # The tool's data as the command would print it.
  defp as_json({:ok, data}), do: data |> Jason.encode!() |> Jason.decode!()

  defp grant!(ctx) do
    send(self(), {:mix_shell_input, :prompt, "y"})

    Grant.run(
      ~w(--models codex:gpt-6-luna --session s1 --max-dispatches 4 --max-parallel 2),
      context(ctx, interactive: true)
    )

    printed!()
  end

  defp tool_args(extra \\ %{}) do
    Map.merge(
      %{
        "purpose" => "implement",
        "worker" => "codex:gpt-6-luna",
        "title" => "Make add return the sum",
        "brief" => @brief,
        "files" => ["calc.py"]
      },
      extra
    )
  end

  defp cli_args(ctx, extra \\ []),
    do:
      ~w(--purpose implement --worker codex:gpt-6-luna --title) ++
        ["Make add return the sum", "--brief", ctx.brief, "--file", "calc.py"] ++ extra

  test "dispatch refuses as the command does, and needs a grant", ctx do
    assert {:error, message} = Tools.call("dispatch", tool_args(), ctx.binding)
    assert message =~ "No grant for session s1"

    assert_raise Refusal, fn -> Dispatch.run(cli_args(ctx), context(ctx)) end

    grant!(ctx)

    assert {:error, "Outside the grant: that model is not granted. Nothing was queued."} =
             (fn ->
                {:ok, _} = ModelCatalog.add("codex", "gpt-6.1-sol")
                Tools.call("dispatch", tool_args(%{"worker" => "codex:gpt-6.1-sol"}), ctx.binding)
              end).()

    assert {:error, "A review needs --of DISPATCH, the completed IMPLEMENT to review"} =
             Tools.call("dispatch", tool_args(%{"purpose" => "review"}), ctx.binding)

    assert {:error, "`attempts` must be a positive integer"} =
             Tools.call("dispatch", tool_args(%{"attempts" => "2"}), ctx.binding)

    assert {:error, "`files` must be a list of strings"} =
             Tools.call("dispatch", tool_args(%{"files" => "calc.py"}), ctx.binding)

    assert {:error, "dispatch needs `title`"} =
             Tools.call("dispatch", Map.delete(tool_args(), "title"), ctx.binding)
  end

  test "a dry run and a dispatch return the command's JSON; the command replays the tool's dispatch",
       ctx do
    grant!(ctx)

    dry = as_json(Tools.call("dispatch", tool_args(%{"dry_run" => true}), ctx.binding))
    Dispatch.run(cli_args(ctx, ["--dry-run"]), context(ctx))
    assert dry == printed!()
    assert %{"would_dispatch" => true, "plan" => %{"tasks" => [_]}} = dry
    assert Repo.all(Shoestring.Dispatches.Dispatch) == []

    # Arguments cannot move a dispatch to another session or repository.
    created =
      as_json(
        Tools.call(
          "dispatch",
          tool_args(%{
            "session_id" => "s2",
            "repository" => "/elsewhere",
            "repo" => "/elsewhere"
          }),
          ctx.binding
        )
      )

    assert %{"outcome" => "recorded", "state" => "queued", "session_id" => "s1"} = created
    assert created["repository_root"] =~ Path.basename(ctx.repo)

    # Same session and request: the command derives the same request id.
    Dispatch.run(cli_args(ctx), context(ctx))
    replayed = printed!()
    assert replayed["outcome"] == "replayed"
    assert Map.delete(replayed, "outcome") == Map.delete(created, "outcome")
  end

  test "an uncommitted checkout: EXPLORE goes ahead naming what its copy lacks; IMPLEMENT refuses only changed tracked files",
       ctx do
    grant!(ctx)
    File.write!(Path.join(ctx.repo, "notes.md"), "untracked\n")
    File.write!(Path.join(ctx.repo, "calc.py"), "changed\n")

    assert {:error, message} = Tools.call("dispatch", tool_args(), ctx.binding)
    assert message =~ "calc.py"
    refute message =~ "notes.md"
    assert message =~ ".git/info/exclude"

    explore =
      tool_args(%{"purpose" => "explore", "title" => "Look around"}) |> Map.delete("files")

    assert {:ok, %{"purpose" => "explore", "left_out" => %{"paths" => paths, "more" => 0}}} =
             Tools.call("dispatch", explore, ctx.binding)

    assert Enum.sort(paths) == ["calc.py", "notes.md"]

    git!(ctx.repo, ["checkout", "--", "calc.py"])

    assert {:ok, %{"purpose" => "implement", "left_out" => %{"paths" => ["notes.md"]}}} =
             Tools.call("dispatch", tool_args(), ctx.binding)
  end

  test "runs tools return the command's JSON for this session's dispatches only", ctx do
    grant!(ctx)
    %{"dispatch_id" => id} = as_json(Tools.call("dispatch", tool_args(), ctx.binding))

    list = as_json(Tools.call("runs_list", %{}, ctx.binding))
    Runs.run(["list"], context(ctx))
    assert list == printed!()
    assert [%{"dispatch_id" => ^id}] = list

    show = as_json(Tools.call("runs_show", %{"dispatch" => id}, ctx.binding))
    Runs.run(["show", id], context(ctx))
    assert show == printed!()

    log = as_json(Tools.call("runs_log", %{"dispatch" => id, "after" => 0}, ctx.binding))
    Runs.run(["log", id], context(ctx))
    assert log == printed!()
    assert {:error, _} = Tools.call("runs_log", %{"dispatch" => id, "after" => -1}, ctx.binding)

    other = %{ctx.binding | session_id: "s2"}
    assert {:ok, []} = Tools.call("runs_list", %{}, other)

    for tool <- ~w(runs_show runs_log runs_cancel) do
      assert {:error, "Dispatch not found in this session: " <> ^id} =
               Tools.call(tool, %{"dispatch" => id, "reason" => "not mine"}, other)
    end

    assert {:error, "Dispatch not found in this session: nope"} =
             Tools.call("runs_show", %{"dispatch" => "nope"}, ctx.binding)

    assert {:error, "`reason` is required"} =
             Tools.call("runs_cancel", %{"dispatch" => id}, ctx.binding)

    assert {:ok, %{"dispatch_id" => ^id}} =
             Tools.call(
               "runs_cancel",
               %{"dispatch" => id, "reason" => "changed my mind"},
               ctx.binding
             )
  end

  test "capacity and advice return the command's JSON", ctx do
    assert as_json(Tools.call("capacity", %{}, ctx.binding)) == as_json({:ok, Capacity.report()})
    Shoestring.CLI.Commands.Capacity.run([], context(ctx))
    assert as_json(Tools.call("capacity", %{}, ctx.binding)) == printed!()

    Advice.run([], context(ctx))
    assert as_json(Tools.call("advice", %{}, ctx.binding)) == printed!()
  end
end
