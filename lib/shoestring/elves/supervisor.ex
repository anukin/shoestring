defmodule Shoestring.Elves.Supervisor do
  @moduledoc """
  Independently supervises one-shot Elf workers, one per bounded harness run.

  ## Strategy

  `:one_for_one` via `DynamicSupervisor`: an Elf crash never takes down its
  siblings, the web/UI layer, or the rest of the application. Each Elf is
  `:temporary` (see `Shoestring.Elves.Elf.child_spec/1`): a crashed Elf is
  never hammer-restarted — crash-looping would risk duplicating an uncertain
  external effect. Recovery is explicit through `Shoestring.Elves.reconcile/2`,
  which re-attaches to (or explicitly terminates) the owned OS process group
  before any replacement may launch.

  ## Test discipline

  This supervisor boots with zero children in every environment, so unlike the
  capacity monitors there is nothing to disable in test config: no Elf — and
  therefore no OS process — can exist unless a test (or operator flow)
  explicitly starts one. Tests that need isolation start their own unnamed
  supervisor via `start_supervised!/1` and pass it as `supervisor:`; every
  `Shoestring.Elves` entrypoint accepts that override.
  """

  use DynamicSupervisor

  @doc """
  Child spec with `restart: :transient` so that a supervision-tree collapse
  (bare `:shutdown` exit) is never re-armed by the parent, mirroring the
  capacity supervisor discipline. A straight `:permanent` restart here would
  risk re-spawning Elves — and their external effects — after a deliberate
  shutdown.
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

  @doc """
  Starts the Elf supervisor.

  ## Options

    * `:name` - supervisor registration name (defaults to `__MODULE__`).
      Pass `nil` for an unnamed supervisor (used by isolated tests).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> DynamicSupervisor.start_link(__MODULE__, opts)
      name -> DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
