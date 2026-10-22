defmodule Shoestring.TextRuns do
  @moduledoc "Explicit manual text-only dispatch. No repository tools or subscription admission claims."
  alias Shoestring.Harness.{Dispatches, OpenAIResponses, OllamaLocal, RunRequest}

  def enqueue(provider, goal, task, prompt, opts \\ []) do
    with {:ok, adapter} <- adapter(provider),
         {:ok, _} <-
           Shoestring.Harness.HTTP.Providers.configuration(adapter.identity().adapter_id),
         {:ok, request} <-
           RunRequest.new(%{
             version: 1,
             goal_id: goal,
             task_id: task,
             dispatch_id: Keyword.get(opts, :dispatch_id, Ecto.UUID.generate()),
             workspace_ref: "manual-text",
             prompt: prompt,
             continuation: nil,
             policy: %{"mode" => "supervised", "write_access" => false},
             requested_capabilities: [:cancel],
             extensions: %{}
           }) do
      Dispatches.enqueue(request, adapter.identity(), opts)
    else
      _ -> {:error, :text_dispatch_not_configured_or_valid}
    end
  end

  defp adapter("api"), do: {:ok, OpenAIResponses}
  defp adapter("local"), do: {:ok, OllamaLocal}
  defp adapter(_), do: {:error, :unsupported_text_provider}

  def from_file(provider, goal, task, path, opts \\ []) do
    with {:ok, %{type: :regular, size: size}} when size in 1..12_000 <- File.stat(path),
         {:ok, prompt} <- File.read(path) do
      if is_nil(goal) and is_nil(task),
        do: create(provider, prompt, opts),
        else: enqueue(provider, goal, task, prompt, opts)
    else
      _ -> {:error, :bounded_prompt_file_required}
    end
  end

  def create(provider, prompt, opts \\ []) do
    with {:ok, adapter} <- adapter(provider),
         {:ok, _} <-
           Shoestring.Harness.HTTP.Providers.configuration(adapter.identity().adapter_id),
         {:ok, _} <- Shoestring.Harness.Contract.text(prompt, :prompt, max: 12_000),
         {:ok, {goal, task}} <-
           Shoestring.Repo.transaction(fn ->
             goal =
               %Shoestring.Trajectory.Goal{}
               |> Shoestring.Trajectory.Goal.create_changeset(Ecto.UUID.generate(), %{
                 title: "Manual text response"
               })
               |> Shoestring.Repo.insert!()

             task =
               %Shoestring.Trajectory.Task{goal_id: goal.id}
               |> Shoestring.Trajectory.Task.changeset(%{title: "One-shot text response"})
               |> Shoestring.Repo.insert!()

             {goal, task}
           end) do
      enqueue(provider, goal.id, task.id, prompt, opts)
    else
      _ -> {:error, :text_dispatch_not_configured_or_valid}
    end
  end
end
