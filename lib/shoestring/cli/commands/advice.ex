defmodule Shoestring.CLI.Commands.Advice do
  @moduledoc "`shoestring advice`: what past runs of each kind looked like."

  alias Shoestring.CLI.{Command, Refusal}

  @help """
  shoestring advice [--json]

  For each kind of run — harness, model, effort, purpose and task class (the
  checks its task cites) — what its finished runs looked like: the median
  and 90th-percentile tokens the harness reported, the share of first
  attempts that were accepted, mean attempts per task, the median duration
  and, for Codex runs measured inside a collection window, the share of the
  provider's usage window a run used. A kind needs #{Shoestring.Advice.min_runs()} finished runs before any of this
  is shown; until then it says so, with its count. Every figure carries its
  sample count and date range.

  It is arithmetic over Shoestring's records — no model call, no training —
  and it never changes admission or dispatch. A coordinator can read it to
  choose models; `shoestring dispatch --dry-run` shows the line for the
  worker it names. Output is JSON on stdout.
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {_opts, [], []} ->
        context.with_repo.(fn repo -> Command.json(context, Shoestring.Advice.report(repo)) end)

      _ ->
        Refusal.usage!("advice")
    end
  end
end
