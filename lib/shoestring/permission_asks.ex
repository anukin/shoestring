defmodule Shoestring.PermissionAsks do
  @moduledoc """
  A worker asking, mid-run, for more than its sandbox allows (iteration 16
  permissions): Codex's approval requests (`approvalPolicy: "on-request"`),
  which come only for a command run outside the sandbox or a file change it
  would refuse, and Claude Code's `can_use_tool` permission requests, which
  come only for a command it wants to run outside the sandbox. Approving one
  runs that one command outside the sandbox (VERIFIED offline with Codex
  0.166.0 and Claude Code 2.1.316): the person is told so.

  Only the person decides (`decide/4` takes a `human:` identity, and the
  chat screen and the Sessions page both answer through
  `Shoestring.Attention.answer/5`); the first answer wins, and nothing is
  ever decided by a timer, and an unanswered ask holds its worker until its
  session ends. The worker's session registers each ask it is waiting on
  (`Shoestring.PermissionAsks.Registry`); an ask whose session is gone can no
  longer be answered and is recorded as expired.

  "Allow for this agent" (`decide/4` with `"allow_agent"`) also adds the
  ask's exact command to its agent's rules (`Shoestring.Agents.allow_command/2`);
  a later ask from that agent's workers for exactly that command is allowed
  at once, recorded as decided by `rule:<agent>`. Only a command a rule may
  cover is offered (`rule_key`; never a file change or a compound shell
  command), and rules are read at each ask, so removing one applies at once.
  """

  import Ecto.Query

  alias Shoestring.{Dispatches, Repo}
  alias Shoestring.PermissionAsks.Ask

  @registry Shoestring.PermissionAsks.Registry
  @max_text 4_000
  @decisions ["allow", "allow_agent", "deny"]

  def registry, do: @registry

  @doc """
  Records an ask from the calling worker session, which waits for
  `{:permission_decision, ask_id, decision, note}` (decision `:allow` or
  `:deny`). `attrs`: `:goal_id`, `:run_id`, `:provider`, `:command`,
  `:reason`, `:cwd`, `:kind` (`"command"`, the default, `"file_change"` or
  `"network"`), and `:rule_key`, the exact command a rule may cover
  (nil for anything else). An ask an agent's rule covers is allowed at once:
  the decision is sent straight back.
  """
  def ask(attrs) do
    dispatch =
      attrs[:goal_id] &&
        Repo.one(from d in Dispatches.Dispatch, where: d.goal_id == ^attrs.goal_id, limit: 1)

    ask =
      Repo.insert!(%Ask{
        goal_id: attrs.goal_id,
        run_id: to_string(attrs.run_id),
        provider: attrs.provider,
        command: clip(attrs.command) || "(no command given)",
        reason: clip(attrs[:reason]),
        cwd: clip(attrs[:cwd]),
        kind:
          if(attrs[:kind] in ~w(command file_change network), do: attrs[:kind], else: "command"),
        rule_key:
          if(Shoestring.Agents.Permissions.ruleable?(attrs[:rule_key]), do: attrs[:rule_key]),
        dispatch_id: dispatch && dispatch.id,
        session_id: dispatch && dispatch.session_id,
        agent: dispatch && dispatch.agent
      })

    {:ok, _} = Registry.register(@registry, ask.id, nil)

    if ask.rule_key && Shoestring.Agents.allows_command?(ask.agent, ask.rule_key) do
      {:ok, ask} = settle(ask, "allowed", "rule:" <> ask.agent, nil)
      send(self(), {:permission_decision, ask.id, :allow, nil})
      {:ok, ask}
    else
      broadcast(ask)
      {:ok, ask}
    end
  end

  @doc """
  The person's decision on a pending ask: `"allow"`, `"allow_agent"` (allow,
  and let the agent's workers run this exact command again without asking)
  or `"deny"`, with an optional `note` for a denial (its reason reaches the
  worker). `{:ok, ask}`, or `{:error, :not_pending | :ask_gone |
  :non_human_identity | :invalid_decision | :not_ruleable | :agent_gone |
  :too_many_rules | :agent_changed}`; nothing is decided or added on an error.
  """
  def decide(ask_id, decision, by, note \\ nil)

  def decide(ask_id, decision, "human:" <> name = by, note) when name != "" do
    with true <- decision in @decisions || {:error, :invalid_decision},
         %Ask{state: "pending"} = ask <- Repo.get(Ask, ask_id) || {:error, :not_pending} do
      case Registry.lookup(@registry, ask.id) do
        [{pid, _}] ->
          {state, answer, note} = outcome(decision, note)

          # Settling and the rule are one write: two screens answering at
          # once can't leave a rule behind for an ask the other one denied.
          Repo.transaction(fn ->
            with {:ok, ask} <- mark(ask, state, by, note),
                 :ok <- add_rule(decision, ask) do
              ask
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
          |> case do
            {:ok, ask} ->
              broadcast(ask)
              send(pid, {:permission_decision, ask.id, answer, if(answer == :deny, do: note)})
              {:ok, ask}

            {:error, _} = error ->
              error
          end

        [] ->
          _ = settle(ask, "expired", nil, nil)
          {:error, :ask_gone}
      end
    else
      %Ask{} -> {:error, :not_pending}
      {:error, _} = error -> error
    end
  end

  def decide(_ask_id, _decision, _by, _note), do: {:error, :non_human_identity}

  defp outcome("allow", _note), do: {"allowed", :allow, nil}
  defp outcome("deny", note), do: {"denied", :deny, clip(note)}

  defp outcome("allow_agent", _note),
    do: {"allowed", :allow, "Allowed for this agent: it runs this command again without asking."}

  defp add_rule("allow_agent", %Ask{rule_key: nil}), do: {:error, :not_ruleable}

  defp add_rule("allow_agent", ask) do
    with {:ok, _agent} <- Shoestring.Agents.allow_command(ask.agent, ask.rule_key), do: :ok
  end

  defp add_rule(_decision, _ask), do: :ok

  # Only a pending ask is decided, once.
  defp settle(ask, state, by, note) do
    with {:ok, ask} <- mark(ask, state, by, note) do
      broadcast(ask)
      {:ok, ask}
    end
  end

  defp mark(ask, state, by, note) do
    now = DateTime.utc_now()

    {count, _} =
      from(a in Ask, where: a.id == ^ask.id and a.state == "pending")
      |> Repo.update_all(
        set: [state: state, decided_by: by, note: note, decided_at: now, updated_at: now]
      )

    if count == 1, do: {:ok, Repo.get!(Ask, ask.id)}, else: {:error, :not_pending}
  end

  @doc "The calling session's ask ended without a decision (its run stopped)."
  def expire(ask_id),
    do: with(%Ask{} = ask <- Repo.get(Ask, ask_id), do: settle(ask, "expired", nil, nil))

  @doc """
  The asks a coordinator session's workers are waiting on now, oldest first;
  with no session, every session's.
  """
  def pending do
    from(a in Ask,
      where: not is_nil(a.session_id) and a.state == "pending",
      order_by: [a.inserted_at, a.id]
    )
    |> Repo.all()
    |> Enum.filter(&waiting?/1)
  end

  def pending(session_id) do
    from(a in Ask,
      where: a.session_id == ^session_id and a.state == "pending",
      order_by: [a.inserted_at, a.id]
    )
    |> Repo.all()
    |> Enum.filter(&waiting?/1)
  end

  @doc "Every ask of a goal's runs, oldest first."
  def for_goal(goal_id),
    do: Repo.all(from a in Ask, where: a.goal_id == ^goal_id, order_by: [a.inserted_at, a.id])

  @doc "Whether a worker session is still waiting on the ask."
  def waiting?(%Ask{state: "pending", id: id}), do: Registry.lookup(@registry, id) != []
  def waiting?(_ask), do: false

  def topic(session_id), do: "permission_asks:#{session_id}"

  defp broadcast(%Ask{session_id: nil}), do: :ok

  # The session's screens hear the ask itself; every screen showing the
  # needs-you count hears that it may have changed.
  defp broadcast(%Ask{} = ask) do
    Phoenix.PubSub.broadcast(Shoestring.PubSub, topic(ask.session_id), {:permission_ask, ask.id})
    Shoestring.Attention.changed(ask.session_id)
  end

  defp clip(nil), do: nil
  defp clip(text) when is_binary(text), do: String.slice(text, 0, @max_text)
  defp clip(other), do: clip(inspect(other))
end
