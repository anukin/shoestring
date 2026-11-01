defmodule Shoestring.Cobbler.Parallelism do
  @moduledoc """
  How many IMPLEMENT tasks may run at once (iteration 16 C2): the person's
  Settings value, turned into iteration 7's reservation policy.

  At 1 (the default) nothing changes: no policy, no fan-out, every task
  sequential. At N >= 2 the global, provider-account and goal limits are N,
  each task weighs one unit of N, and fan-out is on, so a plan's independent
  tasks (a batch IMPLEMENT dispatch, or a `shoestring do` plan whose tasks
  declare separate files) may run together, each in its own worktree.

  Trusted application configuration (`:plan_fanout`, `:plan_reservation_policy`)
  still takes precedence, as tests and iteration 7 use it. The value may not
  change while any work holds a reservation or claim: the same policy must
  govern every held reservation.
  """
  alias Shoestring.AgentProfiles
  alias Shoestring.Cobbler.{Commands, Reservations}

  @max 8

  def max, do: @max

  @doc "The Settings value, 1 when it cannot be read."
  def tasks do
    AgentProfiles.settings().parallel_tasks || 1
  rescue
    _ -> 1
  end

  @doc "The reservation policy to use, or nil for the sequential path."
  def policy do
    case Application.get_env(:shoestring, :plan_reservation_policy) do
      nil -> policy(tasks())
      configured -> configured
    end
  end

  def policy(n) when is_integer(n) and n >= 2,
    do: %{
      "version" => 1,
      "global_limit" => n,
      "provider_account_limit" => n,
      "goal_limit" => n,
      "account_units" => n,
      "task_units" => 1
    }

  def policy(_n), do: nil

  @doc "Whether the fan-out driver may run."
  def fanout? do
    case Application.get_env(:shoestring, :plan_fanout) do
      nil -> tasks() >= 2
      config -> Keyword.get(config, :enabled, false) == true or tasks() >= 2
    end
  end

  @doc "Whether any work holds a reservation or the task claim now."
  def busy? do
    Reservations.outstanding() != [] or Commands.active_claim() != nil
  end
end
