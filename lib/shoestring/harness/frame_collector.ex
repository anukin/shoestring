defmodule Shoestring.Harness.FrameCollector do
  @moduledoc """
  Reads one headless CLI run's line-delimited JSON output from its
  `Shoestring.Elves.PortRunner` until the process exits, for the one-call
  adapters (EXPLORE, REVIEW and the planner).

  The run may be long, so the whole stream is never held: each complete line
  is decoded once, shown to `:each` (progress), and kept only when `:keep`
  wants it (the frames the caller's result is read from). What is kept is
  bounded (`max_kept_bytes/0`, else `:output_too_large`); what is dropped,
  such as a command's output or a file's contents, costs nothing past its own
  line. Nothing kept is truncated.

  The run ends one of four ways, and in every way but a clean exit the whole
  owned process group is terminated, never just the direct child:

    * the process exits 0: `{:ok, frames}`, oldest first;
    * it exits otherwise: `{:error, :transport_error}`;
    * `:deadline_ms` passes (nil waits as long as it runs):
      `{:error, :transport_timeout}`;
    * the collecting process is sent `{:cancel_call, reason}`:
      `{:error, :cancelled}`.
  """

  alias Shoestring.Elves.PortRunner

  @max_kept_bytes 8_388_608
  @max_line_bytes 16_777_216

  def max_kept_bytes, do: @max_kept_bytes
  def max_line_bytes, do: @max_line_bytes

  @doc """
  Collects `runner`'s frames. Options: `:deadline_ms` (nil: none), `:keep`
  (`frame -> boolean`, default every frame), `:each` (`frame -> any`, called
  for every frame), `:max_kept_bytes` and `:max_line_bytes` (one line, kept
  or not).
  """
  def collect(%PortRunner{} = runner, opts \\ []) do
    deadline =
      case Keyword.get(opts, :deadline_ms) do
        nil -> nil
        ms -> System.monotonic_time(:millisecond) + ms
      end

    state = %{
      deadline: deadline,
      keep: Keyword.get(opts, :keep, fn _frame -> true end),
      each: Keyword.get(opts, :each),
      max: Keyword.get(opts, :max_kept_bytes, @max_kept_bytes),
      max_line: Keyword.get(opts, :max_line_bytes, @max_line_bytes),
      pending: "",
      frames: [],
      kept: 0
    }

    loop(runner, state)
  end

  @doc "Asks the process collecting a run to end it (`{:error, :cancelled}`)."
  def cancel(pid, reason \\ :cancelled) when is_pid(pid), do: send(pid, {:cancel_call, reason})

  defp loop(%PortRunner{port: port} = runner, state) do
    timeout =
      case state.deadline do
        nil -> :infinity
        deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
      end

    receive do
      {^port, {:data, data}} ->
        case lines(state, data) do
          {:ok, state} ->
            loop(runner, state)

          {:error, reason} ->
            _ = PortRunner.terminate(runner)
            {:error, reason}
        end

      {^port, {:exit_status, 0}} ->
        _ = PortRunner.close(runner)

        case line(state, state.pending) do
          {:ok, state} -> {:ok, Enum.reverse(state.frames)}
          {:error, reason} -> {:error, reason}
        end

      {^port, {:exit_status, _status}} ->
        _ = PortRunner.close(runner)
        {:error, :transport_error}

      {:cancel_call, _reason} ->
        _ = PortRunner.terminate(runner)
        {:error, :cancelled}
    after
      timeout ->
        _ = PortRunner.terminate(runner)
        {:error, :transport_timeout}
    end
  end

  defp lines(state, data) do
    {complete, [rest]} = (state.pending <> data) |> String.split("\n") |> Enum.split(-1)

    if byte_size(rest) > state.max_line do
      {:error, :output_too_large}
    else
      Enum.reduce_while(complete, {:ok, %{state | pending: rest}}, fn text, {:ok, state} ->
        case line(state, text) do
          {:ok, state} -> {:cont, {:ok, state}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp line(state, text) when byte_size(text) > state.max_line, do: {:error, :output_too_large}

  defp line(state, text) do
    with true <- String.starts_with?(text, "{"),
         {:ok, %{} = frame} <- Jason.decode(text) do
      if state.each, do: state.each.(frame)

      cond do
        not state.keep.(frame) ->
          {:ok, state}

        state.kept + byte_size(text) > state.max ->
          {:error, :output_too_large}

        true ->
          {:ok, %{state | frames: [frame | state.frames], kept: state.kept + byte_size(text)}}
      end
    else
      _ -> {:ok, state}
    end
  end
end
