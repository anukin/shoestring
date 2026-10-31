defmodule Shoestring.Conversations do
  @moduledoc """
  Coordinator conversations (iteration 15 package C): one current per
  session, held in its own goal's trajectory and driven by one
  `Shoestring.Conversations.Engine`. A handoff
  (`Shoestring.Conversations.Handoff`) continues the session in a new one.
  """

  import Ecto.Query

  alias Shoestring.{Harnesses, Repo, Trajectory}
  alias Shoestring.Conversations.{Conversation, Engine, History}
  alias Shoestring.Trajectory.Goal

  @session ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/

  @doc """
  The session's conversation, recorded on first use. `attrs`: `:session_id`,
  `:provider` (a harness that can `:converse`), `:model`, `:effort` and
  `:repository_root`. Opening it again with the same coordinator returns it;
  a different coordinator is refused, since the provider session it resumes
  belongs to the first.
  """
  def open(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with :ok <- session(attrs["session_id"]),
         :ok <- converses(attrs["provider"]),
         {:ok, conversation} <- find_or_insert(attrs),
         :ok <- same_coordinator(conversation, attrs),
         {:ok, _event} <- record_opened(conversation) do
      {:ok, conversation}
    end
  end

  # The session names the conversation's directory (its chat token), so it
  # has the grant's session format.
  defp session(id) when is_binary(id),
    do: if(Regex.match?(@session, id), do: :ok, else: {:error, :invalid_session})

  defp session(_id), do: {:error, :invalid_session}

  defp converses(provider) when is_binary(provider) do
    if Harnesses.supports?(provider, :converse),
      do: :ok,
      else: {:error, {:cannot_converse, provider}}
  end

  defp converses(provider), do: {:error, {:cannot_converse, provider}}

  defp find_or_insert(attrs) do
    case get(attrs["session_id"]) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> insert(attrs)
    end
  end

  defp insert(attrs), do: Repo.transaction(fn -> insert!(attrs, Ecto.UUID.generate(), nil) end)

  # Inside a transaction.
  defp insert!(attrs, id, predecessor_id) do
    with {:ok, _goal} <-
           %Goal{id: id}
           |> Goal.create_changeset(Ecto.UUID.generate(), %{
             title: "Coordinator conversation #{attrs["session_id"]}",
             description: "Conversation of coordinator session #{attrs["session_id"]}."
           })
           |> Repo.insert(),
         {:ok, conversation} <-
           Repo.insert(%Conversation{
             id: id,
             session_id: attrs["session_id"],
             provider: attrs["provider"],
             model: attrs["model"],
             effort: attrs["effort"],
             repository_root: attrs["repository_root"],
             predecessor_id: predecessor_id
           }) do
      conversation
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp same_coordinator(conversation, attrs) do
    if conversation.provider == attrs["provider"] and conversation.model == attrs["model"] and
         conversation.effort == attrs["effort"] and
         conversation.repository_root == attrs["repository_root"],
       do: :ok,
       else: {:error, :conversation_has_another_coordinator}
  end

  # Idempotent, so a conversation whose first open stopped before this event
  # gets it on the next.
  defp record_opened(conversation, opts \\ []) do
    payload =
      %{
        "session_id" => conversation.session_id,
        "provider" => conversation.provider,
        "model" => conversation.model,
        "repository_root" => conversation.repository_root
      }
      |> then(&if(conversation.effort, do: Map.put(&1, "effort", conversation.effort), else: &1))

    Trajectory.append(
      conversation.id,
      %{
        "type" => "conversation.opened",
        "schema_version" => 1,
        "actor" => "conversation",
        "idempotency_key" => "opened",
        "payload" => payload
      },
      opts
    )
  end

  @doc """
  Hands `conversation` off to the successor its
  `conversation.handoff.prepared` payload names, in one transaction: the
  old conversation is marked handed off and gets `conversation.handed_off`;
  the successor is created in the same session and gets
  `conversation.opened` and `conversation.handoff.received`. Asking again
  after it happened returns the successor.
  """
  def hand_off(%Conversation{} = conversation, %{"successor_id" => successor_id} = prepared) do
    in_transaction = [writer_opts: [transaction_repo: Repo]]

    received =
      prepared
      |> Map.delete("successor_id")
      |> Map.put("predecessor_id", conversation.id)

    Repo.transaction(fn ->
      old = Repo.get!(Conversation, conversation.id)
      if old.handed_off_at, do: Repo.rollback(:already_handed_off)
      Repo.update!(Ecto.Changeset.change(old, handed_off_at: DateTime.utc_now()))

      attrs = Map.new(Map.from_struct(old), fn {key, value} -> {to_string(key), value} end)
      successor = insert!(attrs, successor_id, old.id)

      with {:ok, opened} <- record_opened(successor, in_transaction),
           {:ok, received} <-
             append(successor.id, "conversation.handoff.received", received, in_transaction),
           {:ok, handed_off} <-
             append(
               old.id,
               "conversation.handed_off",
               %{"successor_id" => successor.id},
               in_transaction
             ) do
        {successor, [opened, received, handed_off]}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {successor, events}} ->
        # The writer publishes only what it appends outside a transaction.
        for event <- events,
            do:
              Phoenix.PubSub.broadcast(
                Shoestring.PubSub,
                Trajectory.topic(event.goal_id),
                {:trajectory_event_committed, event}
              )

        {:ok, successor}

      {:error, :already_handed_off} ->
        case Repo.get_by(Conversation, predecessor_id: conversation.id) do
          nil -> {:error, :already_handed_off}
          successor -> {:ok, successor}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append(goal_id, type, payload, opts) do
    Trajectory.append(
      goal_id,
      %{
        "type" => type,
        "schema_version" => 1,
        "actor" => "conversation",
        "idempotency_key" => String.replace_prefix(type, "conversation.", ""),
        "payload" => payload
      },
      opts
    )
  end

  @doc """
  Where `shoestring chat` writes the coordinator's instructions for the
  session; the engine reads them each time it starts the coordinator.
  """
  def instructions_path(session_id),
    do: Path.join([Shoestring.State.root(), "chat", session_id, "conversation-instructions.md"])

  @doc "The session's current conversation (the one not handed off), or nil."
  def get(session_id) when is_binary(session_id),
    do:
      Repo.one(
        from c in Conversation, where: c.session_id == ^session_id and is_nil(c.handed_off_at)
      )

  def get(_session_id), do: nil

  @doc "The conversation rebuilt from its events."
  def history(%Conversation{id: id}) do
    with {:ok, events} <- Trajectory.replay(id), do: {:ok, History.from_events(events)}
  end

  @doc """
  Starts the conversation's engine, or returns the running one. A
  conversation handed off has none: `{:error, :handed_off}`.
  """
  def start(%Conversation{} = conversation, opts \\ []) do
    case Repo.get(Conversation, conversation.id) do
      %Conversation{handed_off_at: nil} -> start_engine(conversation, opts)
      _ -> {:error, :handed_off}
    end
  end

  defp start_engine(conversation, opts) do
    case DynamicSupervisor.start_child(
           Shoestring.Conversations.Supervisor,
           {Engine, {conversation, opts}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The running engine of a conversation, or nil."
  def engine(%Conversation{id: id}) do
    case Registry.lookup(Shoestring.Conversations.Registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  The session's inbox, oldest first, each entry with whether a turn has
  delivered it (the `read_inbox` tool). Empty when the session has no
  conversation.
  """
  def inbox(session_id) do
    with %Conversation{} = conversation <- get(session_id),
         {:ok, history} <- history(conversation) do
      {:ok,
       Enum.map(history.inbox, fn entry ->
         %{
           "entry_id" => entry.id,
           "dispatch_id" => entry.dispatch_id,
           "state" => entry.state,
           "purpose" => entry.purpose,
           "title" => entry.title,
           "worker" => entry.worker,
           "recorded_at" => entry.at,
           "delivered" => History.delivered?(history, entry.id)
         }
       end)}
    else
      nil -> {:ok, []}
      error -> error
    end
  end
end
