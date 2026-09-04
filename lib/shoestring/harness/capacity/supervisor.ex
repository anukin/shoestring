defmodule Shoestring.Harness.Capacity.Supervisor do
  @moduledoc """
  Independently supervises the Claude and Codex capacity monitors.

  ## Strategy

  `:one_for_one`: a crash in one provider monitor restarts only that monitor.
  The surviving provider, the web/UI layer, and the rest of the application are
  never taken down by a single-provider failure. `:one_for_all` and
  `:rest_for_one` were deliberately rejected — they would restart (or kill) the
  healthy provider as collateral whenever the other provider crashes, violating
  the locked "provider monitors fail independently" decision.

  ## Restart intensity

  `max_restarts: 3, max_seconds: 60` (far less permissive than OTP's `3/5s`
  default): a monitor that crash-loops more than three times in a minute stops
  being hammer-restarted and the failure escalates visibly instead:
  `Shoestring.Harness.Capacity.SupervisionWatcher` (a younger sibling under the
  same parent, so it survives the outage) emits a `Logger.error` stating that
  capacity monitoring is disabled until an explicit operator restart or
  redeploy, plus a
  `:telemetry.execute([:shoestring, :capacity, :supervisor, :exhausted], ...)`
  event. This is a second layer of defence — the primary bound lives inside
  the monitors themselves (Codex backs off reconnects with capped exponential
  backoff; Claude degrades to last-known state), and neither monitor crashes
  when its provider CLI is simply absent (Codex settles in `:incompatible`,
  Claude in pre-first-response `unknown`). Booting with neither provider
  available is therefore healthy boot with honest unknown state, never a crash
  loop.

  ## Child restart (`:transient`)

  When this supervisor itself runs as a child (of `Shoestring.Supervisor` in
  production, or of a test root in tests), it restarts `:transiently`: a
  crash-looping monitor that exhausts `max_restarts/0` terminates this
  supervisor with the bare exit reason `:shutdown` (OTP reports
  `:reached_max_restart_intensity` only in its log report, never in the exit
  term), and that shutdown exit is *not* restarted by the parent. A
  `:transient` child is never re-armed on `:normal`, `:shutdown`, or
  `{:shutdown, term}`, so the outage stops at capacity supervision instead of
  hammer-restarting up the tree and collapsing the root supervisor, the web/UI
  layer, the Repo, and the healthy provider's host tree.

  Once this supervisor gives up it stays down for the life of the VM — there
  is deliberately no automatic recovery loop. A persistent crash loop signals
  a poisoned/defective monitor, and silently re-arming it would re-create the
  very restart storm this setting bounds. Capacity data is non-critical-path:
  the observatory reads the durable ledger, so while supervision is down the
  UI keeps serving honest last-known/stale/unknown state. Recovery is an
  explicit operator action (restart the supervisor or redeploy).

  ## Configuration

  Per-provider entries under `config :shoestring, :capacity_monitors`:

      config :shoestring, :capacity_monitors,
        claude: [enabled: true],
        codex: [enabled: true]

  Each entry supports `enabled:` plus any monitor `start_link` option, which is
  passed through (e.g. `codex: [enabled: true, base_backoff_ms: 2_000]`).
  An explicit `:claude`/`:codex` entry in `start_link/1` starts that child
  unless it carries `enabled: false`; without one, the application config
  decides. The test environment disables both entries, so the
  application boots a healthy empty supervisor there: no monitor is auto-started
  and no provider CLI is ever shelled out to. Tests start monitors explicitly
  via `start_supervised!/1`.
  """

  use Supervisor

  alias Shoestring.Harness.Capacity.ClaudeMonitor
  alias Shoestring.Harness.Capacity.CodexMonitor

  @doc """
  Child spec with `restart: :transient` so restart-intensity exhaustion
  (bare `:shutdown` exit; OTP's `:reached_max_restart_intensity` appears only
  in its log report, never in the exit term) is never re-armed by the
  parent supervisor. See the "Child restart" section in the moduledoc.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient,
      shutdown: :infinity
    }
  end

  @max_restarts 3
  @max_seconds 60

  @doc "Maximum crash-loop restarts before the failure escalates instead of hammering."
  @spec max_restarts() :: non_neg_integer()
  def max_restarts, do: @max_restarts

  @doc "Window in seconds over which `max_restarts/0` is counted."
  @spec max_seconds() :: pos_integer()
  def max_seconds, do: @max_seconds

  @doc """
  Starts the capacity supervisor.

  ## Options
    * `:name` - supervisor registration name (defaults to `__MODULE__`).
      Pass `nil` for an unnamed supervisor.
    * `:claude` - keyword overrides for the Claude child (`:enabled` plus
      `ClaudeMonitor.start_link/1` options).
    * `:codex` - keyword overrides for the Codex child (`:enabled` plus
      `CodexMonitor.start_link/1` options).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl Supervisor
  def init(opts) do
    children =
      [claude_child_spec(opts), codex_child_spec(opts)]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  @doc """
  Builds the Claude monitor child spec, or `nil` when disabled.

  The child id is `:claude_monitor` so it can be addressed independently
  (`Supervisor.terminate_child/2`, `Supervisor.restart_child/2`).
  """
  @spec claude_child_spec(keyword()) :: Supervisor.child_spec() | nil
  def claude_child_spec(opts \\ []) do
    case resolve_provider_opts(:claude, opts) do
      nil ->
        nil

      monitor_opts ->
        monitor_opts = Keyword.put_new(monitor_opts, :name, ClaudeMonitor)

        %{
          id: :claude_monitor,
          start: {ClaudeMonitor, :start_link, [monitor_opts]},
          restart: :permanent,
          shutdown: 5_000,
          type: :worker
        }
    end
  end

  @doc """
  Builds the Codex monitor child spec, or `nil` when disabled.

  The child id is `:codex_monitor` so it can be addressed independently
  (`Supervisor.terminate_child/2`, `Supervisor.restart_child/2`).
  """
  @spec codex_child_spec(keyword()) :: Supervisor.child_spec() | nil
  def codex_child_spec(opts \\ []) do
    case resolve_provider_opts(:codex, opts) do
      nil ->
        nil

      monitor_opts ->
        monitor_opts = Keyword.put_new(monitor_opts, :name, CodexMonitor)

        %{
          id: :codex_monitor,
          start: {CodexMonitor, :start_link, [monitor_opts]},
          restart: :permanent,
          shutdown: 5_000,
          type: :worker
        }
    end
  end

  # Returns monitor start_link opts, or nil when the provider is disabled.
  #
  # Precedence: an explicit per-provider entry in `start_link` options means
  # "start this child" unless it carries `enabled: false`; without an explicit
  # entry the application config decides (defaulting to enabled). Monitor
  # tuning options merge (explicit wins); `:enabled` itself is resolved, never
  # passed to the monitor.
  defp resolve_provider_opts(provider, opts) do
    configured = Application.get_env(:shoestring, :capacity_monitors, [])
    configured = if is_list(configured), do: configured, else: []

    base = Keyword.get(configured, provider, [])
    explicit? = Keyword.has_key?(opts, provider)
    overrides = Keyword.get(opts, provider, [])

    if base === false or overrides === false do
      nil
    else
      base = if is_list(base), do: base, else: []
      overrides = if is_list(overrides), do: overrides, else: []
      merged = Keyword.merge(base, overrides)

      enabled =
        cond do
          Keyword.has_key?(overrides, :enabled) -> Keyword.get(overrides, :enabled)
          explicit? -> true
          true -> Keyword.get(base, :enabled, true)
        end

      if enabled do
        Keyword.delete(merged, :enabled)
      else
        nil
      end
    end
  end
end
