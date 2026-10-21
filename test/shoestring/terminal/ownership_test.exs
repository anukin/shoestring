defmodule Shoestring.Terminal.OwnershipTest do
  use ExUnit.Case, async: true
  alias Shoestring.Terminal.Ownership

  test "takeover fences agent input until a trusted safe boundary" do
    {:ok, busy} = Ownership.agent_input(%Ownership{})
    {:ok, requested} = Ownership.request(busy, "browser-a", self())
    assert requested.state == :takeover_requested
    assert {:error, :terminal_owned} = Ownership.agent_input(requested)
    assert {:error, :not_input_owner} = Ownership.human_input(requested, "browser-a", self())
    human = Ownership.boundary(requested)
    assert :ok = Ownership.human_input(human, "browser-a", self())
    assert {:error, :not_input_owner} = Ownership.human_input(human, "browser-b", self())
    assert {:error, :terminal_owned} = Ownership.agent_input(human)
    {:ok, released} = Ownership.release(human, "browser-a", self())
    assert {:ok, _} = Ownership.agent_input(released)
  end

  test "detach keeps ownership, rejects another client and requires explicit release" do
    {:ok, human} = Ownership.request(%Ownership{}, "browser-a", self())
    detached = Ownership.detach(human, self())
    assert detached.state == :detached_human_owned
    assert {:error, :terminal_owned} = Ownership.agent_input(detached)
    assert {:error, :terminal_owned} = Ownership.request(detached, "browser-b", self())
    {:ok, reattached} = Ownership.request(detached, "browser-a", self())
    assert reattached.state == :human_owned
    assert {:ok, %{state: :agent_owned}} = Ownership.release(reattached, "browser-a", self())
  end

  test "a disconnected takeover requester remains detached after boundary" do
    {:ok, busy} = Ownership.agent_input(%Ownership{})
    {:ok, pending} = Ownership.request(busy, "browser-a", self())
    detached = pending |> Ownership.detach(self()) |> Ownership.boundary()
    assert detached.state == :detached_human_owned
    assert {:error, :terminal_owned} = Ownership.agent_input(detached)
  end
end
