defmodule Shoestring.ApiSpendConcurrencyTest do
  use ExUnit.Case, async: false
  alias Shoestring.ApiSpend
  alias Shoestring.ApiSpend.Reservation
  alias Shoestring.Test.ApiSpendHelpers, as: F
  alias Shoestring.Test.MigrationRepo, as: Repo
  @moduletag :tmp_dir
  @now ~U[2026-10-20 12:00:00.000000Z]

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:shoestring, :api_execution)

    Application.put_env(:shoestring, :api_execution, %{F.config() | monthly_cap_microusd: 957_288})

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:shoestring, :api_execution, config)
        :error -> Application.delete_env(:shoestring, :api_execution)
      end
    end)

    opts = [
      database: Path.join(dir, "spend.db"),
      pool_size: 1,
      journal_mode: :wal,
      busy_timeout: 5000
    ]

    start_supervised!({Repo, opts})

    Ecto.Migrator.run(Repo, Application.app_dir(:shoestring, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    stop_supervised!(Repo)
    options = Keyword.put(opts, :pool_size, 8)
    start_supervised!({Repo, options})
    %{repo_opts: options, opts: [repo: Repo, now: @now]}
  end

  test "independent concurrent connections cannot double-spend three call maxima", c do
    requests = for _ <- 1..8, do: elem(F.request!(Repo), 0)

    results =
      race(Enum.map(requests, fn request -> fn -> ApiSpend.reserve(request, c.opts) end end))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, :api_cap_exceeded})) == 5
    assert Repo.aggregate(Reservation, :sum, :maximum_microusd) == 957_288
  end

  test "one dispatch can reserve exactly once even under concurrent delivery", c do
    {request, _} = F.request!(Repo)
    results = race(for _ <- 1..8, do: fn -> ApiSpend.reserve(request, c.opts) end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :api_call_already_reserved})) == 7
    assert Repo.aggregate(Reservation, :count) == 1
  end

  test "database restart and month rollover keep the full unresolved reservation", c do
    {request, _} = F.request!(Repo)
    assert {:ok, row} = ApiSpend.reserve(request, c.opts)
    stop_supervised!(Repo)
    start_supervised!({Repo, c.repo_opts})

    assert {:ok, %{"reserved_microusd" => 319_096}} =
             ApiSpend.summary(repo: Repo, now: ~U[2027-01-01 00:00:00Z])

    assert {:error, :api_call_already_reserved} = ApiSpend.reserve(request, c.opts)
    assert {:ok, %{status: "unresolved"}} = ApiSpend.unresolved(row.id, c.opts)
    assert {:ok, %{"reserved_microusd" => 319_096}} = ApiSpend.summary(c.opts)
  end

  defp race(calls) do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      Enum.map(calls, fn call ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> call.()
          after
            10_000 -> raise "API spend race start timed out"
          end
        end)
      end)

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid, 10_000 end)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end
end
