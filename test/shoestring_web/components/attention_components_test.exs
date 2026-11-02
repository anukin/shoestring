defmodule ShoestringWeb.AttentionComponentsTest do
  @moduledoc """
  The needs-you cards: what each says, its choices, and that a secret in a
  worker's command or a reviewer's finding is redacted while the rest of
  the text stays.
  """
  use ShoestringWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Shoestring.PermissionAsks.Ask
  alias ShoestringWeb.AttentionComponents

  @secret "abc.def.ghi"

  defp card(item, extra \\ %{}),
    do:
      render_component(
        &AttentionComponents.card/1,
        Map.merge(%{item: item, reason_for: nil, reason_error: nil}, extra)
      )

  defp ask_item(command, why) do
    %{
      id: "ask-a1",
      kind: :ask,
      ask: %Ask{id: "a1", kind: "command"},
      title: "A worker asks to run a command outside its sandbox",
      subject: "$ " <> command,
      why: why,
      note: "It waits for you: nothing decides this on a timer.",
      choices: [{"allow", "Allow once"}, {"deny", "Deny"}, {"deny_reason", "Deny with a reason"}]
    }
  end

  test "an ask's card redacts a secret in its command and reason, and keeps the rest" do
    html =
      card(
        ask_item(
          "curl -H 'Authorization: Bearer #{@secret}' https://example.test/x",
          "Token Bearer #{@secret} for the mirror"
        )
      )

    refute html =~ @secret
    assert html =~ "[REDACTED]"
    assert html =~ "curl -H"
    assert html =~ "https://example.test/x"
    assert html =~ "for the mirror"
    assert html =~ ~s(id="ask-a1-allow")
    assert html =~ ~s(id="ask-a1-deny-reason")
  end

  test "deny with a reason opens its form in place of the choices" do
    html = card(ask_item("npm ci", nil), %{reason_for: "a1", reason_error: "Write the reason."})
    assert html =~ ~s(id="ask-a1-reason-form")
    assert html =~ ~s(id="ask-a1-reason-error")
    refute html =~ ~s(id="ask-a1-allow")
  end

  test "a stopped dispatch's card gives its findings, redacted, the commands and its run" do
    html =
      card(%{
        id: "stopped-d1",
        kind: :stopped,
        reason: :review,
        title: "A review needs your decision",
        subject: "Make add return the sum",
        note: "Decide in a terminal.",
        lines: ["F1 calc.py:2 leaks Bearer #{@secret} into the log"],
        commands: [~s(shoestring review accept g1 t1 --reason "REASON")],
        run_id: "11111111-1111-4111-8111-111111111111",
        choices: []
      })

    refute html =~ @secret
    assert html =~ "F1 calc.py:2 leaks"
    assert html =~ "into the log"
    assert html =~ ~s(id="stopped-d1-commands")
    assert html =~ "shoestring review accept g1 t1 --reason &quot;REASON&quot;"
    assert html =~ ~s(href="/runs/11111111-1111-4111-8111-111111111111")
    # Nothing on it acts: no buttons.
    refute html =~ "<button"
  end
end
