defmodule Shoestring.Authority do
  @moduledoc """
  Who may decide. `human:NAME` is a person. `grant:UUID` is a coordinator
  session acting under an allowance a person granted (`Shoestring.Grants`).

  A grant identity is only ever written by the dispatch code, which passes
  the dispatch record the grant authorized (`Shoestring.Dispatches`); the
  modules that accept one check that record, so a grant id typed on a
  command line decides nothing. Everything a grant does not cover — review
  waivers, scope decisions, integration, handoffs — stays human-only.
  """

  @human ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/
  @grant ~r/\Agrant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  def human?(identity), do: is_binary(identity) and Regex.match?(@human, identity)
  def grant?(identity), do: is_binary(identity) and Regex.match?(@grant, identity)

  @doc "A human or grant identity, by syntax alone; replay validation uses this."
  def identity?(identity), do: human?(identity) or grant?(identity)

  def grant_identity(grant_id), do: "grant:" <> grant_id

  @doc "The grant id in a grant identity, or nil."
  def grant_id("grant:" <> id = identity), do: if(grant?(identity), do: id)
  def grant_id(_identity), do: nil

  @doc """
  `:ok` when `identity` is a human, or a grant identity that `dispatch`
  (passed by the dispatch code as `opts[:dispatch]`) records for `goal_id`
  and, when given, for exactly `digest`.
  """
  def check(identity, goal_id, digest, opts) do
    cond do
      human?(identity) -> :ok
      grant?(identity) -> granted(identity, goal_id, digest, Keyword.get(opts, :dispatch))
      true -> {:error, :non_human_identity}
    end
  end

  defp granted(identity, goal_id, digest, %{grant_id: grant_id, goal_id: goal_id} = dispatch) do
    cond do
      grant_identity(grant_id) != identity -> {:error, :grant_does_not_cover}
      digest && dispatch.plan_digest != digest -> {:error, :grant_does_not_cover}
      true -> :ok
    end
  end

  defp granted(_identity, _goal_id, _digest, _dispatch), do: {:error, :grant_does_not_cover}
end
