defmodule Shoestring.Harness.Interactive do
  @moduledoc "Interactive PTY adapter. Terminal prose supplies no verdicts, capacity or safe-boundary facts."
  @behaviour Shoestring.Harness.Adapter
  alias Shoestring.Harness.{Error, Identity, RunIdentity}
  alias Shoestring.Terminal.Session

  @impl true
  def identity, do: identity("fixture")

  def identity(provider) when provider in ["fixture", "claude", "codex"] do
    {:ok, identity} =
      Identity.new(%{
        adapter_id: "#{provider}_interactive_pty",
        provider: provider,
        adapter_version: "1",
        schema_version: 1,
        invocation_mode: :process
      })

    identity
  end

  @impl true
  def capabilities, do: MapSet.new([:cancel, :interactive, :send])

  @impl true
  def probe(_opts),
    do:
      {:error,
       Error.new(
         :unsupported_capability,
         "terminal_has_no_capacity",
         "Terminal output is not capacity evidence."
       )}

  @impl true
  def start(request, opts) do
    provider = Map.get(opts, :provider, "fixture")

    child =
      {Session,
       request: request, provider: provider, workdir: Map.fetch!(opts, :workdir), owner: self()}

    with {:ok, run_id} <- Shoestring.Terminal.Events.run_id(request),
         {:ok, _pid} <- DynamicSupervisor.start_child(Shoestring.Terminal.Sessions, child),
         {:ok, pgid} <- Session.ready(run_id) do
      RunIdentity.new(%{
        run_id: run_id,
        harness_id: identity(provider).adapter_id,
        process_id: to_string(pgid)
      })
    else
      _ ->
        {:error,
         Error.new(
           :transport,
           "terminal_start_failed",
           "Interactive terminal could not start; verify the helper and launch profile."
         )}
    end
  catch
    :exit, _ ->
      {:error,
       Error.new(
         :transport,
         "terminal_start_failed",
         "Interactive terminal did not complete its handshake."
       )}
  end

  @impl true
  def stream(identity, _opts) do
    Session.events(identity.run_id)
  catch
    :exit, _ ->
      {:error,
       Error.new(
         :transport,
         "terminal_session_lost",
         "Interactive session is unavailable; no completion is invented."
       )}
  end

  @impl true
  def status(identity, _opts) do
    {:ok, Session.status(identity.run_id)}
  catch
    :exit, _ -> {:ok, %{state: "unavailable"}}
  end

  @impl true
  def send(identity, bytes, _opts), do: Session.agent_input(identity.run_id, bytes)

  @doc "Trusted controller input boundary; raw terminal output cannot invoke this."
  def boundary(identity), do: Session.boundary(identity.run_id)

  @impl true
  def cancel(identity, opts) do
    if Map.get(opts, :boundary) in [:safe, :item, :lease] do
      # A quiet screen or lease timer is not a provider/tool boundary.
      {:ok, :cancelled}
    else
      if Session.lookup(identity.run_id),
        do: Session.cancel(identity.run_id),
        else: {:ok, :cancelled}
    end
  end

  def release(identity) do
    case Session.lookup(identity.run_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Shoestring.Terminal.Sessions, pid)
    end
  end
end
