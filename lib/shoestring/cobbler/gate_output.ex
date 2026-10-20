defmodule Shoestring.Cobbler.GateOutput do
  @moduledoc """
  Redaction of gate output before it is stored or sent anywhere.

  `Trajectory.Redaction` replaces the secret values it recognises. Event
  payloads are then checked by the stricter `Harness.Security` scan, which
  refuses a whole event that still looks like it holds a secret; a gate whose
  tests print one such line would otherwise make its result unrecordable.
  So any line the scan still flags is withheld, and if the joined output is
  still flagged (a pattern spanning lines) all of it is.
  """

  alias Shoestring.Harness.Security
  alias Shoestring.Trajectory.Redaction

  @withheld_line "[REDACTED LINE]"
  @withheld "[REDACTED: gate output withheld]"
  @credential_value ~r/\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|cookie|authorization)\s*[:=]\s*[^\s,;]+/i

  @spec redact(binary() | nil) :: binary() | nil
  def redact(nil), do: nil

  def redact(output) when is_binary(output) do
    if String.valid?(output),
      do: redact_text(output),
      else: "[REDACTED: invalid UTF-8 gate output]\n"
  end

  defp redact_text(output) do
    redacted =
      output
      |> Redaction.redact()
      |> String.replace(@credential_value, "[REDACTED]")
      |> String.split("\n")
      |> Enum.map_join("\n", &if(Security.secret_value?(&1), do: @withheld_line, else: &1))

    if Security.secret_value?(redacted), do: @withheld, else: redacted
  end
end
