defmodule Shoestring.Conversations do
  @moduledoc """
  Coordinator conversations (iteration 15 package C): one per session, held
  in its own goal's trajectory and driven by one
  `Shoestring.Conversations.Engine`.
  """

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

  defp insert(attrs) do
    id = Ecto.UUID.generate()

    Repo.transaction(fn ->
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
               repository_root: attrs["repository_root"]
             }) do
        conversation
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
  defp record_opened(conversation) do
    payload =
      %{
        "session_id" => conversation.session_id,
        "provider" => conversation.provider,
        "model" => conversation.model,
        "repository_root" => conversation.repository_root
      }
      |> then(&if(conversation.effort, do: Map.put(&1, "effort", conversation.effort), else: &1))

    Trajectory.append(conversation.id, %{
      "type" => "conversation.opened",
      "schema_version" => 1,
      "actor" => "conversation",
      "idempotency_key" => "opened",
      "payload" => payload
    })
  end

  @doc "The session's conversation, or nil."
  def get(session_id) when is_binary(session_id),
    do: Repo.get_by(Conversation, session_id: session_id)

  def get(_session_id), do: nil

  @doc "The conversation rebuilt from its events."
  def history(%Conversation{id: id}) do
    with {:ok, events} <- Trajectory.replay(id), do: {:ok, History.from_events(events)}
  end

  @doc "Starts the conversation's engine, or returns the running one."
  def start(%Conversation{} = conversation, opts \\ []) do
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
