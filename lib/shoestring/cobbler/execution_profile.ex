defmodule Shoestring.Cobbler.ExecutionProfile do
  @moduledoc "Immutable saved-agent selection for one approved execution."
  alias Shoestring.AgentProfiles.Revision
  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer}

  @key "shoestring.agent:binding"
  def key, do: @key

  def resolve(nil, _repo), do: {:ok, nil}

  def resolve(attrs, repo) when is_map(attrs) do
    with {:ok, id} <- Ecto.UUID.cast(value(attrs, :profile_id)),
         number when is_integer(number) and number > 0 <- value(attrs, :revision),
         %Revision{} = revision <- repo.get_by(Revision, definition_id: id, number: number),
         true <- revision.digest == value(attrs, :digest),
         configuration when is_map(configuration) <- revision.configuration,
         true <- digest(revision.configuration) == revision.digest,
         true <- Shoestring.Harness.Contract.safe_term?(configuration),
         roles when is_list(roles) <- configuration["roles"],
         role when is_binary(role) <- value(attrs, :role),
         %{} = selected <- Enum.find(roles, &(&1["name"] == role)),
         {:ok, adapter} <- adapter(selected["provider"]),
         model when is_binary(model) and model != "default" <- selected["model"] do
      {:ok,
       %{
         "profile_id" => id,
         "revision" => number,
         "digest" => revision.digest,
         "instructions" => configuration["instructions"],
         "role" => role,
         "provider" => selected["provider"],
         "adapter_id" => adapter.identity().adapter_id,
         "model" => model
       }}
    else
      "default" -> {:error, :explicit_execution_model_required}
      _ -> {:error, :invalid_execution_profile}
    end
  end

  def resolve(_, _repo), do: {:error, :invalid_execution_profile}

  def validate(nil, _repo), do: :ok

  def validate(binding, repo) do
    case resolve(binding, repo) do
      {:ok, ^binding} -> :ok
      _ -> {:error, :invalid_execution_profile}
    end
  end

  def admission(nil, _payload), do: :ok

  def admission(binding, payload) do
    candidate = payload["candidate"] || %{}

    if candidate["provider_id"] == binding["provider"] and
         candidate["adapter_id"] == binding["adapter_id"],
       do: :ok,
       else: {:error, :execution_profile_admission_mismatch}
  end

  def identity(binding) do
    {:ok, adapter} = adapter(binding["provider"])
    adapter.identity()
  end

  def run_authority(repo, run) do
    case (run.extensions || %{})[@key] do
      nil ->
        if Map.has_key?(run.extensions || %{}, Shoestring.Cobbler.PlanBinding.key()) and
             run.provider_id != "shoestring.harness.fake",
           do: {:error, :execution_profile_required},
           else: :ok

      binding ->
        with :ok <- validate(binding, repo),
             true <- run.provider_id == binding["adapter_id"] do
          :ok
        else
          _ -> {:error, :invalid_execution_profile}
        end
    end
  end

  defp adapter("codex"), do: {:ok, CodexAppServer}
  defp adapter("claude"), do: {:ok, ClaudeHeadless}
  defp adapter(_), do: {:error, :unsupported_execution_provider}
  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp digest(configuration),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(configuration)) |> Base.encode16(case: :lower)
end
