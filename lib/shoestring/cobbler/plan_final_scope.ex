defmodule Shoestring.Cobbler.PlanFinalScope do
  @moduledoc "Bounded immutable final-file evidence for a fan-out child's tested commit."
  alias Shoestring.Cobbler.PlanIndependence

  def encode(base, commit, root_run_id, files) do
    json =
      Shoestring.Cobbler.PlanContract.canonical_json(%{
        "version" => 1,
        "accepted_base" => base,
        "commit" => commit,
        "root_run_id" => root_run_id,
        "files" => files
      })

    with {:ok, _} <- decode(json), do: {:ok, json}
  end

  def decode(json) when is_binary(json) and byte_size(json) <= 65_536 do
    with {:ok, scope} when is_map(scope) <- Jason.decode(json),
         true <- Enum.sort(Map.keys(scope)) == ~w(accepted_base commit files root_run_id version),
         true <- scope["version"] == 1,
         true <- full_commit?(scope["accepted_base"]) and full_commit?(scope["commit"]),
         {:ok, _} <- Ecto.UUID.cast(scope["root_run_id"]),
         files when is_list(files) and length(files) <= 1024 <- scope["files"],
         true <- files == Enum.sort(Enum.uniq(files)),
         true <-
           Enum.all?(files, fn file ->
             PlanIndependence.valid_path?(file) and byte_size(file) <= 4096 and
               Shoestring.Harness.Contract.safe_term?(file)
           end) do
      {:ok, scope}
    else
      _ -> {:error, :invalid_final_scope}
    end
  end

  def decode(_), do: {:error, :invalid_final_scope}

  def validate_payload(%{"scope_json" => json, "commit" => commit}) do
    with {:ok, scope} <- decode(json),
         true <- scope["commit"] == commit do
      :ok
    else
      _ ->
        Shoestring.Harness.Contract.invalid(
          :scope_json,
          "must bind bounded final files to the tested commit"
        )
    end
  end

  def validate_payload(_), do: :ok

  defp full_commit?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, value)
end
