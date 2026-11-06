# Seeds a throwaway state directory with synthetic data for documentation
# screenshots. It starts no provider, sends no prompt and uses no network.
#
#     export SHOESTRING_STATE_DIR="$(mktemp -d)/state" SHOESTRING_AUTOMATION=off
#     mix shoestring.state.prepare && mix ecto.create && mix ecto.migrate
#     mix run tools/screenshots/seed.exs
#
# Never point SHOESTRING_STATE_DIR at real state: this writes fake readings,
# a fake team and a fake coordinator session. Run the service only through
# tools/screenshots/serve.sh, whose PATH holds no provider CLI. See
# tools/screenshots/README.md.

Logger.configure(level: :info)

alias Shoestring.{AgentProfiles, Dispatches, Grants, Lessons, ModelCatalog}
alias Shoestring.Harness.{Capacity, CapacitySnapshot, Observatory}

state = System.fetch_env!("SHOESTRING_STATE_DIR")

if String.contains?(state, "Library/Application Support") or
     String.ends_with?(state, ".local/state/shoestring") do
  Mix.raise("Refusing to seed what looks like a real state directory: #{state}")
end

now = DateTime.utc_now()

# Usage: one Codex and one Claude reading.
{:ok, codex} =
  CapacitySnapshot.new(
    %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :observed,
      windows: [
        %{
          kind: "five_hour",
          state: :observed,
          used_percent: 34.0,
          reset_at: DateTime.add(now, 2 * 3600)
        },
        %{
          kind: "weekly",
          state: :observed,
          used_percent: 61.0,
          reset_at: DateTime.add(now, 3 * 86_400)
        }
      ],
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "screenshot_seed",
        provider_id: "codex",
        invocation_mode: "cli",
        event: :explicit_read
      },
      scope: "example-account",
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      observed_at: now,
      reason: nil,
      extensions: %{}
    },
    now: now
  )

{:ok, _, _} = Observatory.ingest(codex, now: now)

reset = now |> DateTime.add(3 * 3600) |> DateTime.truncate(:second)

{:ok, claude} =
  Capacity.normalize(
    :claude,
    :headless_stream_json,
    %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{
        "status" => "allowed",
        "unifiedWindows" => %{
          "five_hour" => %{"utilization" => 0.22, "resetsAt" => DateTime.to_unix(reset)},
          "seven_day" => %{
            "utilization" => 0.47,
            "resetsAt" => DateTime.to_unix(DateTime.add(reset, 4 * 86_400))
          }
        }
      }
    },
    version: "2.1.310",
    now: now,
    captured_at: now
  )

{:ok, _, _} = Observatory.ingest(claude)

# Teams and agents.
{:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
{:ok, _} = ModelCatalog.add("claude", "opus")

{:ok, _team} =
  AgentProfiles.create(%{
    "name" => "Builder",
    "slug" => "builder",
    "purpose" => "Implement small, well-tested changes and have another vendor review them.",
    "instructions" => "Keep each task to one concern. Name the files a task changes.",
    "roles" => [
      %{"name" => "Coordinator", "provider" => "claude", "model" => "opus"},
      %{"name" => "Worker", "provider" => "codex", "model" => "gpt-6-luna"},
      %{"name" => "Reviewer", "provider" => "claude", "model" => "opus"}
    ]
  })

# A coordinator session in a disposable Git repository.
repo = Path.join(Path.dirname(state), "example-project")
File.mkdir_p!(Path.join(repo, "test"))
File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
File.write!(Path.join(repo, "test/__init__.py"), "")
File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")

for args <- [
      ["init", "-q", "-b", "main"],
      ["add", "."],
      ["-c", "user.name=Example", "-c", "user.email=example@example.com", "commit", "-qm", "base"]
    ],
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

{:ok, facts} = Shoestring.Cobbler.Intake.repository(repo)
session = "sess-example"

{:ok, _grant} =
  Grants.create(
    %{
      session_id: session,
      repository_root: facts.root,
      models: ["codex:gpt-6-luna", "claude:opus"],
      purposes: Grants.purposes(),
      max_dispatches: 10,
      max_parallel: 3,
      max_total_seconds: 4 * 3600,
      max_dispatch_seconds: 3600,
      unread_usage: 2,
      max_turns: 20
    },
    "human:operator"
  )

# No coordinator conversation is opened: a running service would wake its
# coordinator when a dispatch settles, and that launches a provider CLI.

dispatch = fn purpose, title ->
  {:ok, dispatch, :recorded} =
    Dispatches.create(%{
      session_id: session,
      request_id: "seed-#{purpose}",
      purpose: purpose,
      provider: "codex",
      model: "gpt-6-luna",
      title: title,
      brief: "#{String.upcase(purpose)} - #{title}\n",
      repository: facts.root
    })

  dispatch
end

_explore = dispatch.("explore", "Where is add() defined and tested?")
implement = dispatch.("implement", "Make add() return the sum of its arguments")

# Lessons: one approved by the coordinator, one waiting for a decision.
{:ok, _} =
  Lessons.propose(
    %{
      "text" => "Run unittest with -B; the bare runner finds no tests.",
      "dispatch" => implement.id
    },
    %{session_id: session, role: "coordinator"}
  )

{:ok, _} =
  Lessons.propose(
    %{"text" => "Keep calc.py free of I/O; tests import it directly."},
    %{
      session_id: session,
      role: "implementer",
      dispatch_id: implement.id,
      origin_key: "seed:1"
    }
  )

IO.puts("Seeded synthetic state in #{state} (session #{session}, repository #{facts.root})")
