defmodule Shoestring.Harness.ConversationMemorySuite do
  @moduledoc "Scripted context retention and isolation; this does not measure model recall quality."

  def env(context) do
    if context[:memory],
      do: [{"FAKE_CONVERSATION_MEMORY", Path.join(context.tmp_dir, "sessions")}],
      else: []
  end

  defmacro __using__(_opts) do
    quote do
      @tag :tmp_dir
      @tag memory: true
      test "scripted context survives process restart and stays separate from a new session",
           ctx do
        spec = %{owner: self(), model: "opus", workdir: ctx.tmp_dir}
        {:ok, first} = open(spec, ctx)
        %{provider_session_id: session} = next_event(first)
        :ok = @conversation.send_turn(first, "remember", "REMEMBER Preserve signed zero.")
        assert List.last(events_until(first, :turn_completed)).status == :completed
        :ok = @conversation.close(first)
        events_until(first, :closed)

        {:ok, resumed} = open(Map.put(spec, :resume, session), ctx)
        assert %{provider_session_id: ^session} = next_event(resumed)
        :ok = @conversation.send_turn(resumed, "recall", "RECALL")
        events = events_until(resumed, :turn_completed)

        assert Enum.filter(events, &(&1.type == :text)) |> Enum.map_join(& &1.text) ==
                 "Preserve signed zero."

        {:ok, sibling} = open(spec, ctx)
        %{provider_session_id: other} = next_event(sibling)
        refute other == session
        :ok = @conversation.send_turn(sibling, "separate", "RECALL")
        events = events_until(sibling, :turn_completed)
        assert Enum.filter(events, &(&1.type == :text)) |> Enum.map_join(& &1.text) == "NO MEMORY"
        :ok = @conversation.close(sibling)
        :ok = @conversation.close(resumed)
      end

      @tag :tmp_dir
      @tag memory: true
      test "missing scripted provider history refuses resume without opening a fresh session",
           ctx do
        assert {:error, _} =
                 open(
                   %{
                     owner: self(),
                     model: "opus",
                     workdir: ctx.tmp_dir,
                     resume: "11111111-2222-4333-8444-555555555555"
                   },
                   ctx
                 )

        refute_received {:conversation_event, _, %{type: :session}}
        refute File.exists?(Path.join([ctx.tmp_dir, "sessions", "calls.jsonl"]))
      end
    end
  end
end
