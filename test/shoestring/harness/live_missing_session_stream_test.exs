defmodule Shoestring.Harness.LiveMissingSessionStreamTest do
  @moduledoc """
  A live run whose provider session is no longer registered.

  Both production adapters answered `stream/2` for an unregistered session
  with their simulated completion: a scripted command, the message
  "Created `test.txt` successfully." and a `completed` result. The Elf polls
  `stream/2` for live runs (`adapter_opts: %{live: true}` from `ElfEffect`), so
  a session that vanished mid-run would have been recorded as a completed run
  that did work it never did.

  LOCK for both adapters: at the pre-fix commit a live read returns
  `{:ok, simulated_events}` with a `completed` result. The hermetic twin (no
  live flag) is documentation that the simulation hermetic tests rely on is
  unchanged. Never a provider CLI, never the network.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer, Error, RunIdentity}

  for {adapter, label} <- [{CodexAppServer, "Codex"}, {ClaudeHeadless, "Claude"}] do
    @adapter adapter

    test "#{label}: a live read with no registered session is an explicit transport error" do
      assert {:error, %Error{category: :transport, code: "session_not_found"}} =
               @adapter.stream(identity(), %{live: true})
    end

    test "#{label}: a hermetic read with no session still returns the simulation" do
      assert {:ok, events} = @adapter.stream(identity(), %{})
      assert Enum.any?(events, &(&1.kind == :result))
    end
  end

  defp identity do
    {:ok, identity} =
      RunIdentity.new(%{
        run_id: Ecto.UUID.generate(),
        harness_id: "elf",
        process_id: nil,
        provider_session_id: nil
      })

    identity
  end
end
