defmodule Shoestring.Elves.LeaseBoundary do
  @moduledoc """
  Lease-deadline enforcement with terminal-only safe stops.

  When a lease deadline passes, the lease is not renewed and the session's
  safe stop is requested through `Session.request_safe_stop/1`. That
  request only pends: the session never sends `turn/interrupt` for it —
  not on request, delta, reasoning activity, completion, timeout, or
  quiet — because no observable frame can rule out a tool start already
  in transit. The authoritative turn outcome resolves the pending stop
  with no send. A deadline therefore never destroys in-flight work, at the
  disclosed cost that deadline pressure waits for the turn to finish.

  This module performs exactly one effect — the safe-stop request — and
  optionally records the deadline as staleness evidence. It never
  terminates anything on its own: explicit human/orchestrator action remains
  the only termination path. Polling a deadline until it passes is covered by
  `Shoestring.Elves.LeaseWatcher`.
  """

  alias Shoestring.Elves.Staleness
  alias Shoestring.Harness.CodexAppServer.Session

  @doc """
  Pure deadline check. Returns true once `now` has reached `deadline`.
  Non-renewal is the caller's policy reading of this boolean: an expired
  lease is left expired, never silently extended here.
  """
  @spec expired?(DateTime.t(), DateTime.t()) :: boolean()
  def expired?(%DateTime{} = deadline, %DateTime{} = now) do
    DateTime.compare(now, deadline) != :lt
  end

  @doc """
  Enforces `deadline` against `session`.

  Returns `{:ok, :within_lease}` while the deadline is in the future.
  Once the deadline has passed, requests the safe stop and returns
  `{:ok, :stop_requested}` — the request pends at the session and the
  authoritative turn outcome resolves it; the turn is never interrupted
  proactively, so in-flight items always run to their own outcome.

  ## Options

    * `:now` — explicit timestamp (default: current UTC time). Tests inject
      the deadline crossing deterministically through this option.
    * `:run_id` — when given, the enforcement is also recorded as
      staleness evidence (`"lease_expired"`), read-only observation that
      deduplicates like every other packet.
    * `:repo`, `:clock` and the `Staleness.collect/3` writer options —
      forwarded to the evidence collection only.
  """
  @spec enforce(GenServer.server(), DateTime.t(), keyword()) ::
          {:ok, :within_lease | :stop_requested} | {:error, term()}
  def enforce(session, %DateTime{} = deadline, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if expired?(deadline, now) do
      case safe_stop(session) do
        {:ok, :stop_requested} ->
          _ = maybe_observe(opts)
          {:ok, :stop_requested}

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, :within_lease}
    end
  end

  # A lease enforcer must not crash on an already-dead session: :noproc
  # becomes a plain error the watcher can log past and keep polling with.
  defp safe_stop(session) do
    Session.request_safe_stop(session)
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp maybe_observe(opts) do
    case Keyword.fetch(opts, :run_id) do
      {:ok, run_id} -> Staleness.collect(run_id, "lease_expired", opts)
      :error -> :skipped
    end
  rescue
    _error -> {:error, :observation_failed}
  catch
    _kind, _reason -> {:error, :observation_failed}
  end
end
