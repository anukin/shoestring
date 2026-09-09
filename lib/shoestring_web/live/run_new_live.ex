defmodule ShoestringWeb.RunNewLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Cobbler
  alias Shoestring.Elves
  alias Shoestring.Harness.Dispatches
  alias Shoestring.Harness.RunRequest
  alias Shoestring.Repo
  alias Shoestring.State
  alias Shoestring.Trajectory
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
     |> assign(:form_errors, %{})
     |> assign(:claim_held, nil)}
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

      expert_bypass?(run_params) and String.trim(run_params["confirmed_by"] || "") == "" ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Expert bypass requires attribution: fill in Confirmed by before submitting."
         )
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
       |> put_flash(:error, "Repository path is not allowed under the configured roots.")
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

  # Manual runs are Cobbler commands, not direct database mutation (WP A):
  # the normal path records an operator-confirmed admission decision, submits
  # a `task.claim` command (exclusive global claim), enqueues gated dispatch
  # (`require_cobbler_command: true`), and only then starts the supervising
  # Elf for the already-persisted intent. Without a live owned claim nothing
  # starts: the claim-held panel is surfaced instead.
  #
  # The expert/test escape hatch (`expert_bypass` + `confirmed_by`) keeps the
  # legacy direct `Elves.start_run`, but its use is logged as a
  # `require_confirmation` admission event first — never silent.
  @claim_intent "manual_execution"
  @claim_scope "account:manual"

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

    task =
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

    bounds = %{
      timeout_seconds: timeout_seconds,
      max_events: max_events,
      lease_seconds: lease_seconds
    }

    provider = run_params["provider"] || "fake"
    candidate = candidate_for(provider)

    extensions = %{
      "shoestring.manual:lease_bounded" => true,
      "shoestring.manual:timeout_seconds" => timeout_seconds,
      "shoestring.manual:max_events" => max_events,
      "shoestring.manual:lease_seconds" => lease_seconds,
      "shoestring.manual:repo_path" => worktree.repo_path,
      "shoestring.manual:base_revision" => worktree.base_commit
    }

    extensions =
      if expert_bypass?(run_params) do
        Map.merge(extensions, %{
          "shoestring.manual:expert_bypass" => true,
          "shoestring.manual:confirmed_by" => String.trim(run_params["confirmed_by"] || "")
        })
      else
        extensions
      end

    {:ok, request} =
      RunRequest.new(%{
        version: 1,
        goal_id: goal.id,
        task_id: task.id,
        workspace_ref: worktree.workspace_ref,
        prompt: prompt,
        continuation: nil,
        policy: %{
          "mode" => "supervised",
          "write_access" => true
        },
        requested_capabilities: [:cancel],
        dispatch_id: run_id,
        extensions: extensions
      })

    {identity, adapter, command, adapter_opts, process_owner} =
      case provider do
        "codex" ->
          {Shoestring.Harness.CodexAppServer.identity(), Shoestring.Harness.CodexAppServer,
           ["codex", "app-server", "--stdio"], %{live: true}, :adapter}

        "claude" ->
          {Shoestring.Harness.ClaudeHeadless.identity(), Shoestring.Harness.ClaudeHeadless,
           ["claude", "--print", "--verbose", "--output-format", "stream-json"], %{live: true},
           :adapter}

        _fake ->
          scenario_name = parse_scenario(run_params["scenario"])

          {Shoestring.Harness.Fake.identity(), Shoestring.Harness.Fake, ["sleep", "30"],
           %{scenario: scenario_name}, :runner}
      end

    elf_opts = [
      run_id: run_id,
      adapter: adapter,
      adapter_opts: adapter_opts,
      process_owner: process_owner,
      command: command,
      runner_opts: [cd: worktree.path, kill_grace_ms: 2_000, reap_timeout_ms: 2_000],
      max_events_per_run: max_events
    ]

    if expert_bypass?(run_params) do
      hatch_start_run(run_params, socket, goal, candidate, bounds, request, identity, elf_opts)
    else
      gated_start_run(socket, goal, candidate, bounds, request, identity, elf_opts, run_id)
    end
  end

  # Gated path: admission → claim → gated dispatch → Elf for persisted intent.
  defp gated_start_run(socket, goal, candidate, bounds, request, identity, elf_opts, run_id) do
    with {:ok, admission} <- append_manual_admission(goal, candidate, bounds),
         {:ok, %{command: command}} <-
           Cobbler.submit_command(goal.id, claim_attrs(candidate, admission, run_id)) do
      case command.status do
        "resolved" ->
          gated_dispatch(socket, request, identity, elf_opts, run_id)

        "needs_user" ->
          hold = hold_details(command)
          Logger.warning("Manual run refused: execution claim held (#{hold.reason})")

          {:noreply,
           socket
           |> put_flash(
             :error,
             "Another run holds the execution claim. This run was not started; " <>
               "confirm or release the claim in the Cobbler dashboard."
           )
           |> assign(:claim_held, hold)}

        "rejected" ->
          Logger.warning("Manual run claim rejected: #{inspect(command.result)}")

          {:noreply,
           socket
           |> put_flash(:error, "Cobbler admission rejected this run. It was not started.")
           |> assign(:form, to_form(socket.assigns.form.params, as: :run))}
      end
    else
      {:error, reason} ->
        Logger.warning("Manual run admission/claim failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Cobbler admission failed. This run was not started.")
         |> assign(:form, to_form(socket.assigns.form.params, as: :run))}
    end
  end

  # The single durable entry for manual execution: gated enqueue refuses goals
  # without a live owned claim instead of bypassing commands. `run_id:` keeps
  # the run row on the worktree/dispatch identity the UI navigates to.
  defp gated_dispatch(socket, request, identity, elf_opts, run_id) do
    case Dispatches.enqueue(request, identity, require_cobbler_command: true, run_id: run_id) do
      {:ok, dispatch, _job} ->
        case Elves.start_elf(request, dispatch, elf_opts) do
          {:ok, _pid} ->
            {:noreply, push_navigate(socket, to: ~p"/runs/#{request.dispatch_id}")}

          {:ok, :already_running, _pid} ->
            {:noreply, push_navigate(socket, to: ~p"/runs/#{request.dispatch_id}")}

          {:error, reason} ->
            Logger.warning("Failed to start Elf for gated run: #{inspect(reason)}")

            {:noreply,
             socket
             |> put_flash(
               :error,
               "Dispatch was recorded but the Elf failed to start. Check server logs."
             )
             |> assign(:form, to_form(socket.assigns.form.params, as: :run))}
        end

      {:error, {:no_claimed_command, detail}} ->
        Logger.warning("Manual run dispatch refused without claim: #{inspect(detail)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "Cobbler claim lost before dispatch (#{detail.reason}). This run was not started."
         )
         |> assign(
           :claim_held,
           %{
             goal_id: request.goal_id,
             command_id: nil,
             reason: to_string(detail.reason),
             holder_goal_id: Map.get(detail, :holder),
             options: []
           }
         )}

      {:error, reason} ->
        Logger.warning("Failed to dispatch gated run: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "Failed to dispatch run. Please retry; if the problem persists, check server logs."
         )
         |> assign(:form, to_form(socket.assigns.form.params, as: :run))}
    end
  end

  # Expert/test escape hatch: direct start, allowed ONLY with explicit
  # attribution, and logged as a `require_confirmation` admission event first.
  defp hatch_start_run(
         run_params,
         socket,
         goal,
         candidate,
         bounds,
         request,
         identity,
         elf_opts
       ) do
    confirmed_by = String.trim(run_params["confirmed_by"] || "")

    with {:ok, _event} <- append_bypass_admission(goal, candidate, bounds, confirmed_by) do
      Logger.warning("Expert bypass manual run started by #{confirmed_by} for goal #{goal.id}")

      case Elves.start_run(request, identity, elf_opts) do
        {:ok, _pid} ->
          {:noreply, push_navigate(socket, to: ~p"/runs/#{request.dispatch_id}")}

        {:ok, :already_running, _pid} ->
          {:noreply, push_navigate(socket, to: ~p"/runs/#{request.dispatch_id}")}

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
    else
      {:error, reason} ->
        Logger.warning("Expert bypass logging failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Bypass audit event failed. This run was not started.")
         |> assign(:form, to_form(run_params, as: :run))}
    end
  end

  defp expert_bypass?(run_params) do
    run_params["expert_bypass"] in [true, "true", "on"]
  end

  defp candidate_for("codex"),
    do: %{"provider_id" => "codex", "adapter_id" => "codex_app_server_stdio"}

  defp candidate_for("claude"),
    do: %{"provider_id" => "claude", "adapter_id" => "claude_headless_stream_json"}

  defp candidate_for(_fake),
    do: %{"provider_id" => "fake", "adapter_id" => "shoestring.harness.fake"}

  defp claim_attrs(candidate, admission, run_id) do
    %{
      "type" => "task.claim",
      "command_id" => "manual-claim-#{run_id}",
      "payload" => %{
        "intent" => @claim_intent,
        "scope" => @claim_scope,
        "candidate" => candidate,
        "admission_event_id" => admission.id
      }
    }
  end

  defp append_manual_admission(goal, candidate, bounds) do
    Trajectory.append(
      goal.id,
      %{
        "type" => "admission.decided",
        "schema_version" => 1,
        "actor" => "operator",
        "occurred_at" => DateTime.utc_now(),
        "payload" =>
          manual_admission_payload(
            candidate,
            bounds,
            "admit",
            "operator_confirmed_manual",
            "Operator-confirmed manual bounded run; local timeout/max-events/lease bounds " <>
              "apply, no automatic quota admission."
          )
      }
    )
  end

  defp append_bypass_admission(goal, candidate, bounds, confirmed_by) do
    Trajectory.append(
      goal.id,
      %{
        "type" => "admission.decided",
        "schema_version" => 1,
        "actor" => "operator",
        "occurred_at" => DateTime.utc_now(),
        "payload" =>
          manual_admission_payload(
            candidate,
            bounds,
            "require_confirmation",
            "operator_confirmed_expert_bypass",
            "Expert/test escape hatch used by #{confirmed_by}: direct start without a " <>
              "Cobbler claim. Auditable bypass, never silent."
          )
      }
    )
  end

  defp manual_admission_payload(candidate, bounds, result, reason_code, explanation) do
    %{
      "decision_id" => Ecto.UUID.generate(),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => explanation,
      "requested_capability" => @claim_intent,
      "candidate" =>
        Map.merge(candidate, %{
          "support_tier" => "manual",
          "compatibility_state" => "compatible"
        }),
      "scope" => @claim_scope,
      "observation" => %{
        "snapshot_id" => nil,
        "confidence" => "unknown",
        "freshness" => "unknown",
        "note" =>
          "Manual execution: no capacity observation consulted; operator-confirmed local bounds apply."
      },
      "policy" => %{"version" => 1},
      "proposed_bounds" => %{
        "response_budget" => bounds.max_events,
        "tool_budget" => 0,
        "checkpoint_cadence" => 1,
        "manual_timeout_seconds" => bounds.timeout_seconds,
        "manual_max_events" => bounds.max_events,
        "manual_lease_seconds" => bounds.lease_seconds
      },
      "reobservation_required" => false,
      "evaluated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp hold_details(command) do
    result = command.result || %{}
    active_claim = result["active_claim"] || %{}

    %{
      goal_id: command.goal_id,
      command_id: command.command_id,
      reason: result["reason"] || "claim_held",
      holder_goal_id: active_claim["goal_id"],
      options: result["options"] || []
    }
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
