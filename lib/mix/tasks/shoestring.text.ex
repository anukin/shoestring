defmodule Mix.Tasks.Shoestring.Text do
  use Mix.Task

  @shortdoc "Queue one explicitly configured local/API text response; no tools or subscription quota"
  @moduledoc """
      mix shoestring.text --provider local|api --prompt-file PATH [--goal UUID --task UUID]

  Creates a goal/task unless both IDs are supplied. Requires operator configuration. Queues for the
  running service without starting providers in this CLI. Prompt input is at
  most 12,000 bytes. API execution remains disabled with a zero cap by default;
  enabling it requires an operator-reviewed price version and positive cap.
  Responses are artifacts, not repository edits or verified task acceptance.
  """
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          provider: [:string, :keep],
          goal: [:string, :keep],
          task: [:string, :keep],
          prompt_file: [:string, :keep]
        ]
      )

    unless rest == [] and invalid == [] and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             is_binary(opts[:provider]) and is_binary(opts[:prompt_file]) and
             is_nil(opts[:goal]) == is_nil(opts[:task]),
           do: Mix.raise("Invalid arguments. See mix help shoestring.text")

    Shoestring.CLI.Repository.with_repo(fn _ ->
      Shoestring.CLI.Jobs.with_client(fn client ->
        case Shoestring.TextRuns.from_file(
               opts[:provider],
               opts[:goal],
               opts[:task],
               opts[:prompt_file],
               oban: client
             ) do
          {:ok, dispatch, _} ->
            Mix.shell().info(
              Jason.encode!(%{
                goal_id: dispatch.goal_id,
                task_id: dispatch.task_id,
                dispatch_id: dispatch.dispatch_id,
                run_id: dispatch.run_id
              })
            )

          {:error, _} ->
            Mix.raise(
              "Text dispatch refused; check configuration, existing task and bounded input."
            )
        end
      end)
    end)
  end
end
