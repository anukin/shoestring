defmodule Shoestring.Harness.ClaudeHeadless.CapacityReading do
  @moduledoc """
  Claude's own usage reports in a headless stream-json run become capacity
  observations: a `rate_limit_event` frame with five-hour and seven-day
  utilization is normalized (`Shoestring.Harness.Capacity`) and handed to a
  sink (default: `Shoestring.Harness.Observatory`, or the
  `:claude_capacity_sink` setting; nil records nothing).

  Used by every Claude path that reads stream-json: worker runs
  (`ClaudeHeadless.Session`), the coordinator conversation
  (`ClaudeHeadless.Conversation`) and EXPLORE / REVIEW calls
  (`ClaudeHeadless.OneShot`). Evidence only: nothing here asks Claude for
  anything, and a frame that yields no observed window, or a failing sink,
  never touches the run.
  """

  require Logger

  alias Shoestring.Harness.{Capacity, CapacitySnapshot, Observatory}

  @doc "The sink a run records readings to when none is given."
  def default_sink, do: Application.get_env(:shoestring, :claude_capacity_sink, Observatory)

  @doc "The CLI version a `system` frame reports, or nil."
  def version(%{"type" => "system", "claude_code_version" => version})
      when is_binary(version) and byte_size(version) <= 64,
      do: version

  def version(_frame), do: nil

  @doc """
  Records `frame` when it is a `rate_limit_event` with at least one observed
  window. Always `:ok`.
  """
  def record(frame, version, sink, now \\ DateTime.utc_now())

  def record(%{"type" => "rate_limit_event"} = frame, version, sink, now) when not is_nil(sink) do
    with {:ok, %CapacitySnapshot{} = snapshot} <-
           Capacity.normalize(:claude, :headless_stream_json, frame,
             version: version,
             now: now,
             captured_at: now,
             adapter_id: "claude_headless_stream_json",
             scope: Application.get_env(:shoestring, :run_submission_scope, "subscription")
           ),
         true <- Enum.any?(snapshot.windows, &(&1.state == :observed)) do
      case deliver(sink, snapshot) do
        {:ok, _outcome, _snapshot} -> :ok
        other -> Logger.warning("Claude capacity reading not recorded: #{inspect(other)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("Claude capacity reading failed: #{inspect(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Claude capacity reading failed: #{inspect({kind, reason})}")
      :ok
  end

  def record(_frame, _version, _sink, _now), do: :ok

  defp deliver(sink, snapshot) when is_atom(sink), do: sink.ingest(snapshot)
  defp deliver(sink, snapshot) when is_function(sink, 1), do: sink.(snapshot)
end
