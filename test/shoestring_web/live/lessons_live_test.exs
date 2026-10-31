defmodule ShoestringWeb.LessonsLiveTest do
  @moduledoc "The Lessons page (iteration 16 B): every lesson, and the person's last word."
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.{Dispatches, Grants, Lessons, ModelCatalog}

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-lessons-live-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["add", "."],
          ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"]
        ],
        do: {_, 0} = System.cmd("git", ["-C", repo | args])

    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    {:ok, _grant} =
      Grants.create(
        %{
          session_id: "s1",
          repository_root: facts.root,
          models: ["codex:gpt-6-luna"],
          purposes: ["implement"],
          max_dispatches: 3,
          max_parallel: 1,
          max_total_seconds: 3_600,
          max_dispatch_seconds: 1_800,
          unread_usage: 0
        },
        "human:operator"
      )

    {:ok, dispatch, :recorded} =
      Dispatches.create(%{
        session_id: "s1",
        request_id: "d1",
        purpose: "implement",
        provider: "codex",
        model: "gpt-6-luna",
        title: "Sum",
        brief: "IMPLEMENT - sum\n",
        repository: repo
      })

    worker = %{session_id: "s1", role: "implementer", dispatch_id: dispatch.id}

    {:ok, waiting} =
      Lessons.propose(%{"text" => "Run unittest with -B."}, Map.put(worker, :origin_key, "t:1"))

    {:ok, other} =
      Lessons.propose(%{"text" => "Prefer tiny commits."}, Map.put(worker, :origin_key, "t:2"))

    {:ok, own} =
      Lessons.propose(
        %{"text" => "Never edit vendor/.", "dispatch" => dispatch.id},
        %{session_id: "s1", role: "coordinator"}
      )

    %{root: facts.root, waiting: waiting, other: other, own: own}
  end

  test "lessons show who proposed and approved them, and the space they take", ctx do
    {:ok, view, _} = live(conn_for(), "/lessons")
    assert has_element?(view, "#lessons-proposed #lesson-#{ctx.waiting.code}")
    assert has_element?(view, "#lesson-#{ctx.waiting.code}-source", "Dispatch")
    assert has_element?(view, "#lessons-approved #lesson-#{ctx.own.code}")

    assert has_element?(
             view,
             "#lesson-#{ctx.own.code}-decided",
             "approved by the coordinator that proposed it"
           )

    assert has_element?(view, "#lessons-total", "3 lessons")
    assert has_element?(view, "#lessons-total", "200.0 MB")
    assert has_element?(view, "#lessons-repository-0", "2 proposed, 1 approved")
    assert has_element?(view, "#nav-lessons")
  end

  test "the person approves reworded, rejects, rewords and retires", ctx do
    {:ok, view, _} = live(conn_for(), "/lessons")

    view
    |> form("#approve-#{ctx.waiting.code}", lesson: %{text: "Always run unittest with -B."})
    |> render_submit()

    assert %{state: "approved", text: "Always run unittest with -B.", decided_by: "human:" <> _} =
             Lessons.get(ctx.waiting.code)

    view |> form("#reject-#{ctx.other.code}", lesson: %{note: "Advice."}) |> render_submit()
    assert %{state: "rejected", decision_note: "Advice."} = Lessons.get(ctx.other.code)

    view
    |> form("#edit-#{ctx.own.code}", lesson: %{text: "Never edit vendor/ by hand."})
    |> render_submit()

    assert Lessons.get(ctx.own.code).text == "Never edit vendor/ by hand."

    view
    |> form("#retire-#{ctx.own.code}", lesson: %{note: "Vendored no more."})
    |> render_submit()

    assert Lessons.get(ctx.own.code).state == "retired"
    assert has_element?(view, "#lessons-decided #lesson-#{ctx.own.code}")
  end

  defp conn_for, do: Phoenix.ConnTest.build_conn()
end
