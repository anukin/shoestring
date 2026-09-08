defmodule Shoestring.Cobbler.DispatchGate do
  @moduledoc """
  Opt-in protection for direct dispatch paths.

  `authorize/2` verifies that a goal currently holds the exclusive global
  task claim before a dispatch may proceed. Direct run paths
  (`Shoestring.Harness.Dispatches.enqueue/3`,
  `Shoestring.Elves.start_run/3`) accept `require_cobbler_command: true` and
  reject with `{:error, {:no_claimed_command, detail}}` when the goal holds
  no live, owned claim, instead of bypassing commands.

  The check is read-only: it never creates commands, claims, or jobs. The
  claim itself is still performed atomically by
  `Shoestring.Cobbler.Commands.submit/3`; this gate only observes it.
  """

  alias Shoestring.Cobbler.Commands

  @doc """
  Returns `:ok` when `goal_id` holds the active global claim, or
  `{:error, {:no_claimed_command, detail}}` otherwise.
  """
  @spec authorize(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def authorize(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Shoestring.Repo)

    case Commands.active_claim(repo: repo) do
      %{goal_id: ^goal_id} = claim ->
        if claim.status == "active" do
          :ok
        else
          {:error, {:no_claimed_command, %{goal_id: goal_id, reason: :claim_not_active}}}
        end

      %{goal_id: holder} ->
        {:error,
         {:no_claimed_command,
          %{goal_id: goal_id, reason: :claim_held_by_other_goal, holder: holder}}}

      nil ->
        {:error, {:no_claimed_command, %{goal_id: goal_id, reason: :no_active_claim}}}
    end
  end
end
