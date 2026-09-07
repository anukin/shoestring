defmodule Shoestring.Cobbler.AdmissionPolicy do
  @moduledoc """
  Versioned policy configuration and operational defaults for admission evaluation.

  Operational Defaults:
  - 20% remaining reserve for the 5-hour window (refuses automatic admission at >= 80% used).
  - 10% remaining reserve for the weekly window (refuses automatic admission at >= 90% used).

  These thresholds are operational reserve margins, not empirical predictions of task cost.
  No task percentage cost is inferred.

  Conservative lease bounds:
  - Response budget: 10 responses
  - Tool budget: 25 tool calls
  - Deadline: 300 seconds (5 minutes)
  - Checkpoint cadence: 1 turn

  Delayed recheck:
  - When a provider rate-limit or reserve reset timestamp is in the past, a delayed
    recheck (default 60 seconds) prevents immediate retry loops.
  """

  alias Shoestring.Harness.Contract

  @version 1

  @enforce_keys [
    :version,
    :five_hour_reserve_percent,
    :weekly_reserve_percent,
    :five_hour_max_used_percent,
    :weekly_max_used_percent,
    :stale_after_seconds,
    :delayed_recheck_seconds,
    :response_budget,
    :tool_budget,
    :deadline_seconds,
    :checkpoint_cadence,
    :reserves,
    :supported_capabilities,
    :candidate_priority
  ]
  defstruct [
    :version,
    :five_hour_reserve_percent,
    :weekly_reserve_percent,
    :five_hour_max_used_percent,
    :weekly_max_used_percent,
    :stale_after_seconds,
    :delayed_recheck_seconds,
    :response_budget,
    :tool_budget,
    :deadline_seconds,
    :checkpoint_cadence,
    :reserves,
    :supported_capabilities,
    :candidate_priority
  ]

  @type t :: %__MODULE__{
          version: 1,
          five_hour_reserve_percent: number(),
          weekly_reserve_percent: number(),
          five_hour_max_used_percent: number(),
          weekly_max_used_percent: number(),
          stale_after_seconds: pos_integer(),
          delayed_recheck_seconds: pos_integer(),
          response_budget: pos_integer(),
          tool_budget: pos_integer(),
          deadline_seconds: pos_integer(),
          checkpoint_cadence: pos_integer(),
          reserves: %{response: non_neg_integer(), tool: non_neg_integer()},
          supported_capabilities: [String.t()],
          candidate_priority: [String.t()]
        }

  @spec version() :: 1
  def version, do: @version

  @doc "Returns the default admission policy with documented operational thresholds."
  @spec default() :: t()
  def default do
    %__MODULE__{
      version: @version,
      five_hour_reserve_percent: 20,
      weekly_reserve_percent: 10,
      five_hour_max_used_percent: 80,
      weekly_max_used_percent: 90,
      stale_after_seconds: 300,
      delayed_recheck_seconds: 60,
      response_budget: 10,
      tool_budget: 25,
      deadline_seconds: 300,
      checkpoint_cadence: 1,
      reserves: %{response: 1, tool: 1},
      supported_capabilities: ["supervised_execution", "read_only"],
      candidate_priority: ["codex", "claude"]
    }
  end

  @doc "Validates and constructs an AdmissionPolicy struct."
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs \\ %{})

  def new(attrs) when is_map(attrs) do
    default_policy = default()

    version = Map.get(attrs, :version, Map.get(attrs, "version", @version))

    with {:ok, 1} <- validate_version(version),
         {:ok, five_hour_reserve} <-
           get_number(
             attrs,
             :five_hour_reserve_percent,
             default_policy.five_hour_reserve_percent
           ),
         {:ok, weekly_reserve} <-
           get_number(attrs, :weekly_reserve_percent, default_policy.weekly_reserve_percent),
         {:ok, five_hour_max_used} <-
           get_number(
             attrs,
             :five_hour_max_used_percent,
             default_policy.five_hour_max_used_percent
           ),
         {:ok, weekly_max_used} <-
           get_number(attrs, :weekly_max_used_percent, default_policy.weekly_max_used_percent),
         {:ok, stale_after} <-
           get_pos_int(attrs, :stale_after_seconds, default_policy.stale_after_seconds),
         {:ok, delayed_recheck} <-
           get_pos_int(attrs, :delayed_recheck_seconds, default_policy.delayed_recheck_seconds),
         {:ok, response_budget} <-
           get_pos_int(attrs, :response_budget, default_policy.response_budget),
         {:ok, tool_budget} <-
           get_pos_int(attrs, :tool_budget, default_policy.tool_budget),
         {:ok, deadline_seconds} <-
           get_pos_int(attrs, :deadline_seconds, default_policy.deadline_seconds),
         {:ok, checkpoint_cadence} <-
           get_pos_int(attrs, :checkpoint_cadence, default_policy.checkpoint_cadence),
         {:ok, reserves} <- get_reserves(attrs, default_policy.reserves),
         {:ok, supported_capabilities} <-
           get_string_list(
             attrs,
             :supported_capabilities,
             default_policy.supported_capabilities
           ),
         {:ok, candidate_priority} <-
           get_string_list(attrs, :candidate_priority, default_policy.candidate_priority) do
      {:ok,
       %__MODULE__{
         version: @version,
         five_hour_reserve_percent: five_hour_reserve,
         weekly_reserve_percent: weekly_reserve,
         five_hour_max_used_percent: five_hour_max_used,
         weekly_max_used_percent: weekly_max_used,
         stale_after_seconds: stale_after,
         delayed_recheck_seconds: delayed_recheck,
         response_budget: response_budget,
         tool_budget: tool_budget,
         deadline_seconds: deadline_seconds,
         checkpoint_cadence: checkpoint_cadence,
         reserves: reserves,
         supported_capabilities: supported_capabilities,
         candidate_priority: candidate_priority
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  @doc "Serializes an AdmissionPolicy struct to a string-keyed map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    %{
      "version" => policy.version,
      "five_hour_reserve_percent" => policy.five_hour_reserve_percent,
      "weekly_reserve_percent" => policy.weekly_reserve_percent,
      "five_hour_max_used_percent" => policy.five_hour_max_used_percent,
      "weekly_max_used_percent" => policy.weekly_max_used_percent,
      "stale_after_seconds" => policy.stale_after_seconds,
      "delayed_recheck_seconds" => policy.delayed_recheck_seconds,
      "response_budget" => policy.response_budget,
      "tool_budget" => policy.tool_budget,
      "deadline_seconds" => policy.deadline_seconds,
      "checkpoint_cadence" => policy.checkpoint_cadence,
      "reserves" => %{
        "response" => policy.reserves.response,
        "tool" => policy.reserves.tool
      },
      "supported_capabilities" => policy.supported_capabilities,
      "candidate_priority" => policy.candidate_priority
    }
  end

  defp validate_version(1), do: {:ok, 1}
  defp validate_version(_), do: Contract.invalid(:version, "must equal #{@version}")

  defp get_number(attrs, key, default) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    if is_number(val) and val >= 0 and val <= 100 do
      {:ok, val}
    else
      Contract.invalid(key, "must be a percentage between 0 and 100")
    end
  end

  defp get_pos_int(attrs, key, default) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    if is_integer(val) and val > 0 do
      {:ok, val}
    else
      Contract.invalid(key, "must be a positive integer")
    end
  end

  defp get_reserves(attrs, default) do
    val = Map.get(attrs, :reserves, Map.get(attrs, "reserves", default))

    cond do
      is_map(val) ->
        resp = Map.get(val, :response, Map.get(val, "response", 0))
        tool = Map.get(val, :tool, Map.get(val, "tool", 0))

        if is_integer(resp) and resp >= 0 and is_integer(tool) and tool >= 0 do
          {:ok, %{response: resp, tool: tool}}
        else
          Contract.invalid(:reserves, "response and tool must be non-negative integers")
        end

      true ->
        Contract.invalid(:reserves, "must be an object")
    end
  end

  defp get_string_list(attrs, key, default) do
    val = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    if is_list(val) and Enum.all?(val, &is_binary/1) do
      {:ok, val}
    else
      Contract.invalid(key, "must be a list of strings")
    end
  end
end
