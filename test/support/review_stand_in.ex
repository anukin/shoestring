defmodule Shoestring.Test.ReviewStandIn do
  @moduledoc """
  A reviewer for hermetic tests; never a provider. It reports the packet it
  was given to `opts[:test_pid]` and answers with one blocking finding at
  `calc.py:2` (`opts[:blocking] == false` makes it a suggestion).
  """
  @behaviour Shoestring.Cobbler.Review.Adapter

  @impl true
  def review(input, opts) do
    packet = Jason.decode!(input["packet_json"])
    if pid = opts[:test_pid], do: send(pid, {:review_input, input, packet})
    severity = if Keyword.get(opts, :blocking, true), do: "blocking", else: "suggestion"

    findings = %{
      "verdict" => "request_changes",
      "summary" => "add() ignores negative zero.",
      "findings" => [
        %{
          "id" => "F1",
          "severity" => severity,
          "path" => "calc.py",
          "line" => 2,
          "claim" => "The sum is not checked for floats.",
          "evidence" => "return a + b",
          "violates" => "acceptance criteria",
          "correction" => "Add a float case to the test.",
          "confidence" => "medium"
        }
      ]
    }

    {:ok, %{json: Jason.encode!(findings), output_tokens: 90}}
  end
end
