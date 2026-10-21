defmodule ShoestringWeb.TerminalChannel do
  @moduledoc "Bounded dedicated terminal transport; attachment cannot spawn a process."
  use Phoenix.Channel
  alias Shoestring.Terminal.Session
  @impl true
  def join("terminal:" <> run_id, %{"capability" => token}, socket) do
    with {:ok, _run} <-
           ShoestringWeb.TerminalAccess.authorize(token, socket.assigns.terminal_browser, run_id),
         pid when is_pid(pid) <- Session.lookup(run_id),
         {:ok, snapshot} <- Session.attach(run_id, socket.assigns.terminal_browser) do
      socket =
        socket
        |> assign(:terminal_run, run_id)
        |> assign(:terminal_monitor, Process.monitor(pid))
        |> assign(:rate, %{at: System.monotonic_time(:second), count: 0, bytes: 0})

      {:ok, snapshot, socket}
    else
      _ -> {:error, %{reason: "terminal_unavailable"}}
    end
  catch
    :exit, _ -> {:error, %{reason: "terminal_unavailable"}}
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}
  @impl true
  def handle_in(event, payload, socket) do
    cost =
      if is_map(payload) and is_binary(payload["data"]), do: byte_size(payload["data"]), else: 0

    case charge(socket, cost) do
      {:ok, socket} -> dispatch(event, payload, socket)
      :error -> {:stop, :normal, {:error, %{reason: "terminal_rate_limit"}}, socket}
    end
  catch
    :exit, _ -> {:reply, {:error, %{reason: "terminal_unavailable"}}, socket}
  end

  @impl true
  def handle_info({:terminal_output, sequence, bytes}, socket) do
    push(socket, "output", %{sequence: sequence, data: Base.encode64(bytes)})
    {:noreply, socket}
  end

  def handle_info({:terminal_status, status}, socket) do
    push(socket, "status", status)
    {:noreply, socket}
  end

  def handle_info({:terminal_detached, :slow_consumer}, socket) do
    push(socket, "detached", %{reason: "slow_consumer"})
    {:stop, :normal, socket}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{terminal_monitor: ref}} = socket
      ) do
    push(socket, "status", %{state: "ended", reason: "session_unavailable", can_input: false})
    {:stop, :normal, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if run_id = socket.assigns[:terminal_run], do: Session.detach(run_id)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp dispatch("input", %{"data" => data}, socket)
       when is_binary(data) and byte_size(data) <= 10_924 do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) in 1..8192 -> action(socket, {:input, bytes})
      _ -> invalid(socket)
    end
  end

  defp dispatch("resize", %{"rows" => rows, "cols" => cols}, socket),
    do: action(socket, {:resize, rows, cols})

  defp dispatch("takeover", %{} = _payload, socket), do: action(socket, :takeover)
  defp dispatch("release", %{} = _payload, socket), do: action(socket, :release)
  defp dispatch("interrupt", %{} = _payload, socket), do: action(socket, {:signal, "INT"})

  defp dispatch("terminate", %{} = _payload, socket) do
    case Shoestring.Elves.cancel_run(socket.assigns.terminal_run) do
      {:ok, _} -> {:reply, :ok, socket}
      _ -> {:reply, {:error, %{reason: "terminal_unavailable"}}, socket}
    end
  end

  defp dispatch("ack", %{"sequence" => sequence}, socket),
    do: respond(Session.ack(socket.assigns.terminal_run, sequence), socket)

  defp dispatch(_event, _payload, socket), do: invalid(socket)

  defp action(socket, action) do
    case Session.action(socket.assigns.terminal_run, socket.assigns.terminal_browser, action) do
      {:ok, _} -> {:reply, {:ok, Session.status(socket.assigns.terminal_run)}, socket}
      result -> respond(result, socket)
    end
  end

  defp respond(:ok, socket), do: {:reply, :ok, socket}

  defp respond({:error, reason}, socket),
    do: {:reply, {:error, %{reason: to_string(reason)}}, socket}

  defp invalid(socket), do: {:reply, {:error, %{reason: "invalid_terminal_message"}}, socket}

  defp charge(socket, bytes) do
    now = System.monotonic_time(:second)
    old = socket.assigns.rate
    rate = if now == old.at, do: old, else: %{at: now, count: 0, bytes: 0}

    if rate.count < 120 and rate.bytes + bytes <= 87_392 and
         elem(Process.info(self(), :message_queue_len), 1) <= 128,
       do:
         {:ok, assign(socket, :rate, %{rate | count: rate.count + 1, bytes: rate.bytes + bytes})},
       else: :error
  end
end
