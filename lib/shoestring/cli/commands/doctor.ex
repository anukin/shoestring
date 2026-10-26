defmodule Shoestring.CLI.Commands.Doctor do
  @moduledoc """
  `shoestring doctor` in the source checkout. The installed release handles
  `doctor` in `shoestringctl` (`Shoestring.Release.doctor/0`), which also
  checks the release itself; both report each agent CLI the same way.
  """

  alias Shoestring.{Harnesses, ModelCatalog}
  alias Shoestring.CLI.{Command, Refusal}
  alias Shoestring.Release.{Doctor, ProviderProbe}

  @help """
  shoestring doctor [--probe-providers] [--json]

  Whether each agent CLI can take work: `binary_missing`, `not_checked`
  (installed; pass --probe-providers to check it), `needs_sign_in`,
  `version_untested`, `ready` or `unknown`. --probe-providers runs only each
  CLI's version and sign-in status commands; no prompt is sent. Also reports
  git and python3, and how many models of each harness are recorded and
  when they were last listed (`shoestring models refresh`). The installed
  release's doctor also checks the release itself. Output is JSON on stdout.
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [probe_providers: :boolean, json: :boolean]) do
      {opts, [], []} ->
        probes =
          if opts[:probe_providers], do: Map.get(context, :probe, &ProviderProbe.report/0).()

        context.with_repo.(fn _repo ->
          Command.json(context, %{
            "git" => installed("git"),
            "python3" => installed("python3"),
            "agents" => Doctor.agents(probes),
            "models" => Map.new(Harnesses.ids(), &{&1, models(&1)})
          })
        end)

      _ ->
        Refusal.usage!("doctor")
    end
  end

  defp installed(name), do: if(System.find_executable(name), do: "installed", else: "missing")

  defp models(id) do
    entries = ModelCatalog.entries(id)

    %{
      "recorded" => length(entries),
      "enabled" => length(ModelCatalog.enabled(id)),
      "last_listed_at" => ModelCatalog.last_listed_at(id)
    }
  end
end
