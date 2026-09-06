defmodule ShoestringWeb.RunNewLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Elves
  alias Shoestring.Harness.RunRequest
  alias Shoestring.Repo
  alias Shoestring.State
  alias Shoestring.Trajectory.{Goal, Task}
  alias Shoestring.Worktrees
  require Logger

  @timeout_min 5
  @timeout_max 3600
  @max_events_min 10
  @max_events_max 5000
  @lease_min 10
  @lease_max 300

  @default_params %{
    "repo_path" => "",
    "base_revision" => "HEAD",
    "provider" => "fake",
    "prompt" => "",
    "timeout_seconds" => 300,
    "max_events" => 1000,
    "lease_seconds" => 60,
    "scenario" => "success"
  }

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)

    {:ok,
     socket
     |> assign(:page_title, "New Manual Run")
     |> assign(:form, to_form(@default_params, as: :run))
     |> assign(:allowed_roots, allowed_repo_roots())
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_event("validate", %{"run" => run_params}, socket) do
    {:noreply, assign(socket, form: to_form(run_params, as: :run))}
  end

  @impl true
  def handle_event("use_fixture_repo", _params, socket) do
    fixture_path = create_temporary_fixture_repo()

    current_params =
      socket.assigns.form.params
      |> Map.put("repo_path", fixture_path)

    {:noreply,
     socket
     |> put_flash(:info, "Initialized temporary fixture repository.")
     |> assign(form: to_form(current_params, as: :run))}
  end

  @impl true
  def handle_event("start_run", %{"run" => run_params}, socket) do
    prompt = String.trim(run_params["prompt"] || "")
    repo_path = String.trim(run_params["repo_path"] || "")

    cond do
      prompt == "" ->
        {:noreply,
         socket
         |> put_flash(:error, "Task prompt is required.")
         |> assign(:form, to_form(run_params, as: :run))}

      repo_path == "" ->
        {:noreply,
         socket
         |> put_flash(:error, "Source repository path is required.")
         |> assign(:form, to_form(run_params, as: :run))}

      true ->
        do_start_run(run_params, socket)
    end
  end

  defp do_start_run(run_params, socket) do
    repo_path =
      case String.trim(run_params["repo_path"] || "") do
        "fixture" -> create_temporary_fixture_repo()
        path -> Path.expand(path)
      end

    if repo_path_allowed?(repo_path) do
      start_run_in_repo(run_params, socket, repo_path)
    else
      Logger.warning("Rejected manual run repo_path outside allowed roots")

      {:noreply,
       socket
       |> assign(:allowed_roots, allowed_repo_roots())
       |> put_flash(
         :error,
         "Repository path is not allowed. Choose a repository under an allowed root " <>
           "(#{Enum.join(allowed_repo_roots(), ", ")})."
       )
       |> assign(:form, to_form(run_params, as: :run))}
    end
  end

  defp start_run_in_repo(run_params, socket, repo_path) do
    run_id = Ecto.UUID.generate()

    base_rev =
      if blank?(run_params["base_revision"]), do: "HEAD", else: run_params["base_revision"]

    case Worktrees.create(repo_path, run_id, base_rev) do
      {:ok, worktree} ->
        launch_run(run_params, worktree, run_id, socket)

      {:error, reason} ->
        Logger.warning("Worktree allocation failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "Worktree allocation failed: invalid repository path or base revision. " <>
             "Check the repository exists and the revision is valid."
         )
         |> assign(:form, to_form(run_params, as: :run))}
    end
  end

  defp launch_run(run_params, worktree, run_id, socket) do
    goal_id = Ecto.UUID.generate()
    task_id = Ecto.UUID.generate()
    prompt = String.trim(run_params["prompt"] || "")
    owner_id = scope_owner_id(socket.assigns.current_scope) || Ecto.UUID.generate()

    goal =
      %Goal{id: goal_id}
      |> Goal.changeset(%{
        "title" => "Manual Run #{String.slice(run_id, 0, 8)}",
        "description" => prompt
      })
      |> Ecto.Changeset.put_change(:owner_id, owner_id)
      |> Repo.insert!()

    _task =
      %Task{id: task_id}
      |> Task.changeset(%{
        "title" => "Task for #{String.slice(run_id, 0, 8)}",
        "description" => prompt
      })
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    timeout_seconds =
      parse_bounded_integer(run_params["timeout_seconds"], 300, @timeout_min, @timeout_max)

    max_events =
      parse_bounded_integer(run_params["max_events"], 1000, @max_events_min, @max_events_max)

    lease_seconds =
      parse_bounded_integer(run_params["lease_seconds"], 60, @lease_min, @lease_max)

    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: goal.id,
        task_id: task_id,
        workspace_ref: worktree.workspace_ref,
        prompt: prompt,
        continuation: nil,
        policy: %{
          "mode" => "supervised",
          "write_access" => true
        },
        requested_capabilities: [:cancel],
        dispatch_id: run_id,
        extensions: %{
          "shoestring.manual:lease_bounded" => true,
          "shoestring.manual:timeout_seconds" => timeout_seconds,
          "shoestring.manual:max_events" => max_events,
          "shoestring.manual:lease_seconds" => lease_seconds,
          "shoestring.manual:repo_path" => worktree.repo_path,
          "shoestring.manual:base_revision" => worktree.base_commit
        }
      })

    provider = run_params["provider"] || "fake"

    {identity, adapter, command, adapter_opts} =
      case provider do
        "codex" ->
          {Shoestring.Harness.CodexAppServer.identity(), Shoestring.Harness.CodexAppServer,
           ["codex", "app-server", "--stdio"], %{}}

        _fake ->
          scenario_name = parse_scenario(run_params["scenario"])

          {Shoestring.Harness.Fake.identity(), Shoestring.Harness.Fake, ["sleep", "30"],
           %{scenario: scenario_name}}
      end

    elf_opts = [
      run_id: run_id,
      adapter: adapter,
      adapter_opts: adapter_opts,
      command: command,
      runner_opts: [cd: worktree.path, kill_grace_ms: 2_000, reap_timeout_ms: 2_000],
      max_events_per_run: max_events
    ]

    case Elves.start_run(request, identity, elf_opts) do
      {:ok, _pid} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{run_id}")}

      {:ok, :already_running, _pid} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{run_id}")}

      {:error, reason} ->
        Logger.warning("Failed to start run: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "Failed to start run. Please retry; if the problem persists, check server logs."
         )
         |> assign(:form, to_form(run_params, as: :run))}
    end
  end

  defp create_temporary_fixture_repo do
    fixture_root = fixture_root()
    File.mkdir_p!(fixture_root)
    unique = "#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
    fixture_dir = Path.join(fixture_root, "shoestring_fixture_repo_#{unique}")
    File.mkdir_p!(fixture_dir)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: fixture_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Shoestring Manual Run"], cd: fixture_dir)

    {_, 0} =
      System.cmd("git", ["config", "user.email", "manual@shoestring.local"], cd: fixture_dir)

    File.write!(Path.join(fixture_dir, "README.md"), "# Fixture Repo\nInitial content\n")

    File.write!(
      Path.join(fixture_dir, "lib.ex"),
      "defmodule Lib do\n  def hello, do: :world\nend\n"
    )

    {_, 0} = System.cmd("git", ["add", "."], cd: fixture_dir)

    {_, 0} =
      System.cmd("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"],
        cd: fixture_dir
      )

    fixture_dir
  end

  defp fixture_root do
    Path.join(State.root(), "manual_fixtures")
  end

  defp repo_path_allowed?(path) do
    canonical_path = canonical_path(path)

    Enum.any?(allowed_repo_roots(), fn root ->
      canonical_path == root or
        if root == "/" do
          String.starts_with?(canonical_path, "/")
        else
          String.starts_with?(canonical_path, root <> "/")
        end
    end)
  end

  defp allowed_repo_roots do
    configured_roots =
      case Application.get_env(:shoestring, :manual_run_allowed_repo_roots) do
        roots when is_list(roots) and roots != [] -> roots
        _ -> [State.root()]
      end

    [fixture_root() | configured_roots]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&canonical_path/1)
    |> Enum.uniq()
  end

  defp canonical_path(path) do
    resolve_symlinks(Path.expand(path), MapSet.new())
  end

  defp resolve_symlinks(path, seen) do
    cond do
      MapSet.member?(seen, path) ->
        path

      Path.dirname(path) == path ->
        path

      true ->
        seen = MapSet.put(seen, path)
        parent = resolve_symlinks(Path.dirname(path), seen)
        candidate = Path.join(parent, Path.basename(path))

        case File.read_link(candidate) do
          {:ok, target} -> resolve_symlinks(Path.expand(target, parent), seen)
          {:error, _reason} -> candidate
        end
    end
  end

  defp parse_scenario("success"), do: :success
  defp parse_scenario("failure"), do: :failure
  defp parse_scenario("quiet_exit"), do: :quiet_exit
  defp parse_scenario(_), do: :success

  defp parse_bounded_integer(val, default, min, max) do
    val
    |> parse_integer(default)
    |> clamp(min, max)
  end

  defp clamp(num, min, max) when is_integer(num) do
    num |> max(min) |> min(max)
  end

  defp parse_integer(val, _default) when is_integer(val), do: val

  defp parse_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_integer(_val, default), do: default

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  defp scope_owner_id(scope) when is_map(scope) do
    case Map.get(scope, :user) || Map.get(scope, "user") do
      user when is_map(user) -> Map.get(user, :id) || Map.get(user, "id")
      _ -> Map.get(scope, :user_id) || Map.get(scope, "user_id")
    end
  end

  defp scope_owner_id(_), do: nil
end
