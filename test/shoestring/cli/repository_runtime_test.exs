defmodule Shoestring.CLI.RepositoryRuntimeTest do
  @moduledoc """
  A CLI command runs without the application: in the test suite the
  application is always running, so this starts a child `mix run --no-start`
  with this build and its own state directory and appends a trajectory event
  and queues a reservation write through `Shoestring.CLI.Repository.with_repo/1`,
  as a capacity confirmation from `shoestring follow` and `shoestring execution
  cancel` do. No provider, network or service.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  @script ~S"""
  alias Shoestring.Trajectory.Goal

  result =
    Shoestring.CLI.Repository.with_repo(fn repo ->
      {:ok, goal} =
        %Goal{} |> Goal.create_changeset(Ecto.UUID.generate(), %{title: "t"}) |> repo.insert()

      appended =
        Shoestring.Trajectory.append(goal.id, %{
          type: "goal.created",
          schema_version: 1,
          actor: "human",
          occurred_at: DateTime.utc_now(),
          payload: %{"title" => "t"}
        })

      queued = Shoestring.Cobbler.ReservationWriter.run(repo, fn -> :delivered end)
      {appended, queued}
    end)

  IO.puts("appended: " <> inspect(match?({{:ok, %{type: "goal.created"}}, _}, result)))
  IO.puts("queued: " <> inspect(elem(result, 1)))
  """

  test "a domain write appends from a runtime without the application", %{tmp_dir: dir} do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "--no-compile", "-e", @script],
        env: [{"MIX_ENV", "test"}, {"SHOESTRING_TEST_STATE_DIR", dir}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "appended: true"
    assert output =~ "queued: :delivered"
  end
end
