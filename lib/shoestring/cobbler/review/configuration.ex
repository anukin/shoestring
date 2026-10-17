defmodule Shoestring.Cobbler.Review.Configuration do
  @moduledoc """
  Trusted cross-review policy for one approved execution. Disabled unless
  `config :shoestring, :plan_review, enabled: true`.

  The reviewer is the explicitly configured adapter, otherwise the `Reviewer`
  role of the execution's own immutable agent revision. "Different provider"
  means a different provider family (Anthropic for `claude`, OpenAI for
  `codex`); two models of one vendor are the same provider. A reviewer of the
  implementer's family, or no reviewer at all, makes review unavailable: the
  task waits for a human waiver and is never approved by its implementer.

  Plans and models never choose any of this: it comes from configuration and
  the saved agent the human approved the execution with.
  """
  alias Shoestring.Cobbler.{ExecutionProfile, PlanContract}
  alias Shoestring.Harness.Contract

  @role "Reviewer"
  @families %{
    "claude" => "anthropic",
    "codex" => "openai",
    "fixture" => "fixture",
    "fake" => "fake"
  }

  @type loaded :: %{
          public: map(),
          adapter: module(),
          adapter_opts: keyword(),
          endpoint: String.t()
        }

  @doc """
  `{:ok, :not_required}`, `{:ok, {:required, loaded}}` or
  `{:ok, {:unavailable, reason}}` for `execution`. Options: `:review_config`
  (instead of the application environment) and `:repo`.
  """
  @spec load(map(), keyword()) ::
          {:ok, :not_required | {:required, loaded()} | {:unavailable, atom()}}
          | {:error, term()}
  def load(execution, opts \\ []) do
    config = Keyword.get(opts, :review_config, Application.get_env(:shoestring, :plan_review, []))

    cond do
      not is_list(config) -> {:error, :invalid_review_configuration}
      Keyword.get(config, :enabled, false) != true -> {:ok, :not_required}
      true -> required(config, execution, opts)
    end
  end

  @doc "The provider family a provider id belongs to, or nil."
  def family(provider), do: Map.get(@families, provider)

  @doc "The admission candidate for a reviewer configuration."
  def candidate(public) do
    %{
      provider_id: public["provider_id"],
      adapter_id: "reviewer.#{public["adapter"]}",
      scope: public["scope"],
      support_tier: public["support_tier"],
      compatibility_state: :compatible,
      capabilities: ["read_only"]
    }
  end

  defp required(config, execution, opts) do
    implementer = get_in(execution, [:agent_profile, "provider"]) || "fake"

    with {:ok, provider, model} <- reviewer(config, execution, opts),
         {:ok, adapter, tier} <- adapter(provider),
         :ok <- distinct(provider, implementer),
         {:ok, model} <- Contract.text(model, :model, max: 100),
         {:ok, limit} <- integer(config, :max_output_tokens, 4096, 1, 8192),
         {:ok, timeout} <- integer(config, :timeout_ms, 180_000, 1, 300_000),
         {:ok, rounds} <- integer(config, :max_rounds, 2, 1, 3),
         {:ok, endpoint} <- endpoint(config, provider) do
      public = %{
        "version" => "1",
        "adapter" => provider,
        "provider_id" => provider,
        "model" => model,
        "scope" => scope(provider),
        "support_tier" => tier,
        "max_output_tokens" => limit,
        "timeout_ms" => timeout,
        "max_rounds" => rounds,
        "implementer_provider" => implementer,
        "endpoint_digest" => PlanContract.digest(%{"endpoint" => endpoint})
      }

      {:ok,
       {:required, %{public: public, adapter: adapter, adapter_opts: config, endpoint: endpoint}}}
    else
      {:unavailable, reason} -> {:ok, {:unavailable, reason}}
      {:error, _} = error -> error
    end
  end

  defp distinct(provider, implementer) do
    cond do
      family(implementer) == nil -> {:unavailable, :implementer_unknown}
      family(provider) == family(implementer) -> {:unavailable, :same_provider}
      true -> :ok
    end
  end

  defp reviewer(config, execution, opts) do
    case Keyword.get(config, :adapter) do
      nil -> profile_reviewer(execution, opts)
      adapter when is_atom(adapter) -> {:ok, Atom.to_string(adapter), Keyword.get(config, :model)}
      _ -> {:error, :invalid_review_configuration}
    end
  end

  defp profile_reviewer(%{agent_profile: %{} = binding}, opts) do
    repo = Keyword.get(opts, :repo, Shoestring.Repo)

    case ExecutionProfile.resolve(Map.put(binding, "role", @role), repo) do
      {:ok, %{"provider" => provider, "model" => model}} -> {:ok, provider, model}
      {:error, :explicit_execution_model_required} -> {:unavailable, :reviewer_model_required}
      {:error, _} -> {:unavailable, :no_reviewer}
    end
  end

  defp profile_reviewer(_execution, _opts), do: {:unavailable, :no_reviewer}

  defp adapter("fixture"), do: {:ok, Shoestring.Cobbler.Review.Fixture, "proactive"}

  # Both run on the subscription the Elves use; every call needs confirmation
  # until its remaining capacity can be read, as for the Claude planner.
  defp adapter("claude"),
    do: {:ok, Shoestring.Cobbler.Review.ClaudeHeadless, "conservative_partial"}

  defp adapter("codex"), do: {:ok, Shoestring.Cobbler.Review.CodexExec, "conservative_partial"}
  defp adapter(_), do: {:unavailable, :unsupported_reviewer}

  defp scope("fixture"), do: "reviewer:fixture"
  defp scope(_provider), do: "subscription"

  # The bound endpoint is the local executable, so a configuration change
  # cannot reroute a recorded review.
  defp endpoint(_config, "fixture"), do: {:ok, "fixture"}

  defp endpoint(config, provider) do
    case Keyword.get(config, :command, provider) do
      command when is_binary(command) and command != "" ->
        if String.contains?(command, <<0>>),
          do: {:error, :invalid_review_endpoint},
          else: {:ok, command}

      _ ->
        {:error, :invalid_review_endpoint}
    end
  end

  defp integer(config, key, default, min, max) do
    value = Keyword.get(config, key, default)

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: {:error, {:invalid_review_configuration, key}}
  end
end
