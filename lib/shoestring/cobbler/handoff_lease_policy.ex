defmodule Shoestring.Cobbler.HandoffLeasePolicy do
  @moduledoc """
  The per-transfer lease policy a `run.handoff` intent may carry, and the
  only thing that decides the receiver's proposed lease bounds.

  A handoff mints the receiver a **brand new** `ExecutionLease` from the
  admit decision's `proposed_bounds`, and those bounds come straight off the
  `Shoestring.Cobbler.AdmissionPolicy` handed to
  `Shoestring.Cobbler.AdmissionEvaluation.evaluate/5`. Before this module
  existed there was exactly one way to influence them — the in-process
  `:policy` option — and `Shoestring.Cobbler.HandoffWorker`, the only
  production consumer of a handoff intent, passes no such option. So in
  production every receiver got `AdmissionPolicy.default()` and no operator
  could say otherwise.

  ## The default deadline is 2700 seconds, and that is deliberate

  `AdmissionPolicy.default()` proposes a 300-second (5 minute) deadline.
  That number was chosen for a *wake* — an already-warm provider session
  being resumed — and it is wrong for a handoff by roughly the cost of a
  cold start. A handoff receiver is a FRESH session on a DIFFERENT provider:
  the supervised Elf has to launch the process group, the provider CLI has
  to boot, authenticate and ingest a composed continuation prompt, and only
  then does the first response become possible. A 300-second deadline
  routinely expired during harness startup, so the transfer was admitted,
  granted and dispatched, and the receiver's lease was already dead on
  arrival.

  The user explicitly relaxed it to **2700 seconds (45 minutes)** to cover
  harness startup plus a useful working window. This is a *deadline*, not a
  budget: it bounds wall-clock, and the response/tool budgets and the
  reserve rule below still bound how much the receiver may actually spend.
  Relaxing the clock does not relax the spend.

  Nothing else moves. `stale_after_seconds` stays at the
  `AdmissionPolicy.default()` value, so a stale observation is judged
  exactly as strictly as before — a longer lease is not a licence to admit
  on an older reading.

  ## Caller input is allow-listed, bounded and fails closed

  An operator may override the bounds per transfer by putting a
  `lease_policy` object on the `run.handoff` payload. Every field is:

    * **allow-listed** — an unknown key is a REJECTED command, never a
      dropped field. Silently ignoring a caller's `deadline_seconds`
      misspelling would hand them a 2700-second lease while they believed
      they had asked for 60;
    * **bounded** — each field has a documented inclusive range (below), so
      a caller cannot propose a week-long deadline or a zero budget;
    * **digest-covered** — it lives on the command payload, so
      `Shoestring.Cobbler.Command.digest/2` covers it. Re-submitting the
      same command id with a different policy is a conflict, not a silent
      re-bounding of an intent that may already be executing;
    * **durable** — `Shoestring.Cobbler.Commands` copies the validated
      policy onto the resolved `handoff_requested` result, which is what
      `Shoestring.Cobbler.Handoffs.perform/3` replays against. Enqueue,
      retry, Oban-table loss and boot reconciliation therefore all reach the
      identical policy: the Oban job carries no bounds of its own and cannot
      drift from the intent.

  ### Bounds

  | field                | range (inclusive) | default |
  |----------------------|-------------------|---------|
  | `deadline_seconds`   | 60 .. 14_400      | 2700    |
  | `response_budget`    | 1 .. 1_000        | 10      |
  | `tool_budget`        | 1 .. 10_000       | 25      |
  | `checkpoint_cadence` | 1 .. 1_000        | 1       |
  | `reserves.response`  | 0 .. 999          | 1       |
  | `reserves.tool`      | 0 .. 9_999        | 1       |

  The floor on `deadline_seconds` is 60, not 1: a deadline shorter than a
  minute cannot outlive harness startup, so accepting one would only
  reproduce the defect this module exists to fix.

  ### The reserve rule, kept safe

  `Shoestring.Cobbler.LeaseBounds` fires renewal-due one reserve EARLY:
  `responses >= response_budget - response_reserve`. A reserve greater than
  or equal to its budget therefore makes the lease renewal-due at zero
  spend — the receiver is granted a lease it can never produce anything
  under, and the transfer completes into an immediately-stalled run. So a
  reserve must be **strictly less than** its budget, and that is validated
  here rather than discovered at execution time.

  ## What this module does NOT do

  It proposes bounds; it does not admit anything. `AdmissionEvaluation` still
  decides, and every hard stop remains a hard stop. A caller cannot widen a
  refusal into an admission with a lease policy, and cannot touch the
  reserve percentages, the staleness window or the capability vocabulary —
  those are not in the allow-list at all.
  """

  alias Shoestring.Cobbler.AdmissionPolicy
  alias Shoestring.Harness.Contract

  @version 1

  # The deadline the user explicitly relaxed from 300s. See the moduledoc.
  @default_deadline_seconds 2700

  @default_response_budget 10
  @default_tool_budget 25
  @default_checkpoint_cadence 1
  @default_response_reserve 1
  @default_tool_reserve 1

  @min_deadline_seconds 60
  @max_deadline_seconds 14_400
  @max_response_budget 1_000
  @max_tool_budget 10_000
  @max_checkpoint_cadence 1_000

  # The allow-list. An unknown key is refused, never dropped.
  @policy_keys ~w(deadline_seconds response_budget tool_budget checkpoint_cadence reserves)
  @reserve_keys ~w(response tool)

  @enforce_keys [
    :version,
    :deadline_seconds,
    :response_budget,
    :tool_budget,
    :checkpoint_cadence,
    :reserves
  ]
  defstruct [
    :version,
    :deadline_seconds,
    :response_budget,
    :tool_budget,
    :checkpoint_cadence,
    :reserves
  ]

  @type t :: %__MODULE__{
          version: 1,
          deadline_seconds: pos_integer(),
          response_budget: pos_integer(),
          tool_budget: pos_integer(),
          checkpoint_cadence: pos_integer(),
          reserves: %{response: non_neg_integer(), tool: non_neg_integer()}
        }

  @spec version() :: 1
  def version, do: @version

  @doc "The handoff default deadline in seconds (2700 — see the moduledoc)."
  @spec default_deadline_seconds() :: pos_integer()
  def default_deadline_seconds, do: @default_deadline_seconds

  @doc "The fields a `lease_policy` object may name."
  @spec policy_keys() :: [String.t()]
  def policy_keys, do: @policy_keys

  @doc """
  The policy a handoff uses when its intent carries no `lease_policy`.

  Identical to `Shoestring.Cobbler.AdmissionPolicy.default()` in every bound
  except the deadline, which is 2700 seconds rather than 300.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      version: @version,
      deadline_seconds: @default_deadline_seconds,
      response_budget: @default_response_budget,
      tool_budget: @default_tool_budget,
      checkpoint_cadence: @default_checkpoint_cadence,
      reserves: %{response: @default_response_reserve, tool: @default_tool_reserve}
    }
  end

  @doc """
  Validates a caller-supplied `lease_policy` object.

  Absent fields take the `default/0` value; unknown keys, out-of-range
  values, non-integers and a reserve that is not strictly below its budget
  are all errors. Returns `{:ok, t()}` or an `Ecto.Changeset` error, so it
  composes with the rest of `Shoestring.Cobbler.Command` validation and a
  bad policy rejects the command instead of reaching delivery.
  """
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs \\ %{})

  def new(attrs) when is_map(attrs) do
    defaults = default()

    with :ok <- reject_unknown_keys(attrs, @policy_keys, :lease_policy),
         {:ok, deadline_seconds} <-
           bounded_int(
             attrs,
             :deadline_seconds,
             defaults.deadline_seconds,
             @min_deadline_seconds,
             @max_deadline_seconds
           ),
         {:ok, response_budget} <-
           bounded_int(attrs, :response_budget, defaults.response_budget, 1, @max_response_budget),
         {:ok, tool_budget} <-
           bounded_int(attrs, :tool_budget, defaults.tool_budget, 1, @max_tool_budget),
         {:ok, checkpoint_cadence} <-
           bounded_int(
             attrs,
             :checkpoint_cadence,
             defaults.checkpoint_cadence,
             1,
             @max_checkpoint_cadence
           ),
         {:ok, reserves} <- reserves(attrs, defaults.reserves),
         :ok <- validate_reserve_rule(reserves, response_budget, tool_budget) do
      {:ok,
       %__MODULE__{
         version: @version,
         deadline_seconds: deadline_seconds,
         response_budget: response_budget,
         tool_budget: tool_budget,
         checkpoint_cadence: checkpoint_cadence,
         reserves: reserves
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:lease_policy, "must be an object")

  @doc "Serializes a policy to the string-keyed map carried on the intent."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    %{
      "deadline_seconds" => policy.deadline_seconds,
      "response_budget" => policy.response_budget,
      "tool_budget" => policy.tool_budget,
      "checkpoint_cadence" => policy.checkpoint_cadence,
      "reserves" => %{
        "response" => policy.reserves.response,
        "tool" => policy.reserves.tool
      }
    }
  end

  @doc """
  Reads the policy off a durable `run.handoff` intent (the resolved
  `handoff_requested` result map).

  An intent carrying no `lease_policy` uses `default/0` — that is the whole
  point of the 2700-second default. An intent carrying a MALFORMED one is an
  error, never a silent fall back to the default: a policy that was validated
  at request time and no longer validates means the durable record disagrees
  with this code, and guessing which side is right is how a receiver ends up
  executing under bounds nobody authorized.
  """
  @spec from_intent(map()) :: {:ok, t()} | {:error, term()}
  def from_intent(intent) when is_map(intent) do
    case Map.get(intent, "lease_policy") do
      nil ->
        {:ok, default()}

      value when is_map(value) ->
        case new(value) do
          {:ok, policy} -> {:ok, policy}
          {:error, changeset} -> {:error, {:invalid_handoff_lease_policy, changeset}}
        end

      other ->
        {:error, {:invalid_handoff_lease_policy, other}}
    end
  end

  def from_intent(_intent), do: {:ok, default()}

  @doc """
  Projects the policy onto an `AdmissionPolicy`, which is what actually
  produces the decision's `proposed_bounds`.

  Only the five lease-bound fields are replaced. The reserve percentages,
  the staleness window, the delayed-recheck interval, the capability
  vocabulary and the candidate priority all keep their `AdmissionPolicy`
  values: a per-transfer lease policy bounds the RECEIVER's lease, and is
  never a channel for loosening admission itself.
  """
  @spec to_admission_policy(t(), AdmissionPolicy.t()) :: AdmissionPolicy.t()
  def to_admission_policy(
        %__MODULE__{} = policy,
        %AdmissionPolicy{} = base \\ AdmissionPolicy.default()
      ) do
    %AdmissionPolicy{
      base
      | response_budget: policy.response_budget,
        tool_budget: policy.tool_budget,
        deadline_seconds: policy.deadline_seconds,
        checkpoint_cadence: policy.checkpoint_cadence,
        reserves: policy.reserves
    }
  end

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------

  defp reject_unknown_keys(attrs, allowed, field) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in allowed))
      |> Enum.sort()

    case unknown do
      [] -> :ok
      keys -> Contract.invalid(field, "contains unsupported fields: #{Enum.join(keys, ", ")}")
    end
  end

  defp bounded_int(attrs, key, default, min, max) do
    case Contract.fetch(attrs, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} -> in_range(value, key, min, max)
    end
  end

  defp in_range(value, _key, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp in_range(_value, key, min, max),
    do: Contract.invalid(key, "must be an integer between #{min} and #{max}")

  defp reserves(attrs, default) do
    case Contract.fetch(attrs, :reserves) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_map(value) ->
        with :ok <- reject_unknown_keys(value, @reserve_keys, :reserves),
             {:ok, response} <-
               bounded_int(value, :response, default.response, 0, @max_response_budget - 1),
             {:ok, tool} <- bounded_int(value, :tool, default.tool, 0, @max_tool_budget - 1) do
          {:ok, %{response: response, tool: tool}}
        end

      {:ok, _other} ->
        Contract.invalid(:reserves, "must be an object")
    end
  end

  # See "The reserve rule, kept safe" in the moduledoc: a reserve at or above
  # its budget is renewal-due at zero spend.
  defp validate_reserve_rule(reserves, response_budget, tool_budget) do
    cond do
      reserves.response >= response_budget ->
        Contract.invalid(
          :reserves,
          "response reserve (#{reserves.response}) must be below response_budget (#{response_budget})"
        )

      reserves.tool >= tool_budget ->
        Contract.invalid(
          :reserves,
          "tool reserve (#{reserves.tool}) must be below tool_budget (#{tool_budget})"
        )

      true ->
        :ok
    end
  end
end
