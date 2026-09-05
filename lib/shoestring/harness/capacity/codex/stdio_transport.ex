defmodule Shoestring.Harness.Capacity.Codex.StdioTransport do
  @moduledoc """
  Production stdio JSON-RPC transport for `codex app-server --stdio`.

  Launches `codex app-server --stdio` as an OS process without shell
  interpolation using an Erlang port, enforces line framing up to
  `max_frame_size`, and communicates safely via message passing.
  """

  @behaviour Shoestring.Harness.Capacity.Codex.Transport

  use GenServer
  require Logger

  @default_command "codex"
  @default_args ["app-server", "--stdio"]
  @default_max_frame_size 262_144

  @doc """
  Starts a new stdio transport process.

  ## Options

    * `:owner` - PID of the owner process to receive transport events (required).
    * `:command` - executable name or path override (default: `"codex"`).
    * `:executable` - explicit resolved executable path (skips `System.find_executable/1`).
    * `:args` - command-line arguments (default: `["app-server", "--stdio"]`).
    * `:max_frame_size` - maximum allowed frame size in bytes (default: `262_144`).
  """
  @impl Shoestring.Harness.Capacity.Codex.Transport
  def start_link(opts) do
    command = Keyword.get(opts, :command, @default_command)
    explicit_path = Keyword.get(opts, :executable)
    exec_path = explicit_path || System.find_executable(command)

    if is_nil(exec_path) do
      {:error, :executable_not_found}
    else
      GenServer.start_link(__MODULE__, Keyword.put(opts, :executable, exec_path))
    end
  end

  @doc "Sends a JSON-RPC frame (map or encoded binary string) over stdio."
  @impl Shoestring.Harness.Capacity.Codex.Transport
  def send_frame(pid, frame) when is_pid(pid) do
    GenServer.call(pid, {:send_frame, frame})
  end

  @doc "Closes the transport and terminates the underlying OS process."
  @impl Shoestring.Harness.Capacity.Codex.Transport
  def close(pid) when is_pid(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc "Returns the OS process ID of the underlying port, or nil if unavailable."
  def os_pid(pid) when is_pid(pid) do
    GenServer.call(pid, :os_pid)
  catch
    :exit, _ -> nil
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.fetch!(opts, :owner)
    max_frame_size = Keyword.get(opts, :max_frame_size, @default_max_frame_size)
    command = Keyword.get(opts, :command, @default_command)
    args = Keyword.get(opts, :args, @default_args)

    exec_path =
      Keyword.get(opts, :executable) ||
        System.find_executable(command)

    case exec_path do
      nil ->
        {:stop, :executable_not_found}

      path when is_binary(path) ->
        open_port(path, args, max_frame_size, owner)
    end
  end

  defp open_port(exec_path, args, max_frame_size, owner) do
    port_opts = [
      :binary,
      :stream,
      {:line, max_frame_size},
      :use_stdio,
      :exit_status,
      args: args
    ]

    try do
      port = Port.open({:spawn_executable, exec_path}, port_opts)
      send(owner, {:codex_transport_connected, self()})

      {:ok,
       %{
         port: port,
         owner: owner,
         max_frame_size: max_frame_size,
         discarding_oversized: false
       }}
    rescue
      error ->
        {:stop, {:port_open_failed, error}}
    end
  end

  @impl GenServer
  def handle_call({:send_frame, frame}, _from, state) do
    encoded =
      cond do
        is_binary(frame) ->
          String.trim_trailing(frame, "\n")

        is_map(frame) ->
          Jason.encode!(frame)

        true ->
          raise ArgumentError, "Frame must be a map or binary"
      end

    try do
      true = Port.command(state.port, [encoded, "\n"])
      {:reply, :ok, state}
    rescue
      e ->
        {:reply, {:error, {:send_failed, e}}, state}
    end
  end

  def handle_call(:close, _from, state) do
    send(state.owner, {:codex_transport_closed, self(), :normal})
    safe_close_port(state.port)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:os_pid, _from, state) do
    os_pid =
      case Port.info(state.port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:reply, os_pid, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    clean_line = String.trim_trailing(line, "\r")

    if state.discarding_oversized do
      send(state.owner, {:codex_transport_error, self(), :oversized_frame})
      {:noreply, %{state | discarding_oversized: false}}
    else
      send(state.owner, {:codex_transport_frame, self(), clean_line})
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state) do
    # Line exceeded max_frame_size
    {:noreply, %{state | discarding_oversized: true}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:codex_transport_closed, self(), {:exit_status, status}})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    send(state.owner, {:codex_transport_closed, self(), reason})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state) do
    safe_close_port(state.port)
    {:stop, reason, state}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state && Map.has_key?(state, :port) do
      safe_close_port(state.port)
    end

    :ok
  end

  defp safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp safe_close_port(_), do: :ok
end
