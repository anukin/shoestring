defmodule ShoestringWeb.DecisionText do
  @moduledoc "The words every screen uses when a decision's answer is refused (iteration 19)."

  @doc "Why an answer to a decision was refused, in plain words."
  def refusal(:already_answered), do: "Someone already answered this decision."
  def refusal(:decision_withdrawn), do: "This decision was withdrawn: its goal was cancelled."
  def refusal(:decision_not_found), do: "That decision is not one of these plans'."
  def refusal(:unknown_option), do: "That is not one of the options."
  def refusal(:reject_not_allowed), do: "This decision does not allow \"none of these\"."
  def refusal(:note_required), do: "Say why none of these will do."
  def refusal(:note_too_long), do: "The note is longer than 2000 characters."
  def refusal(:non_human_identity), do: "Only a person can answer a decision."
  def refusal(other), do: "Could not record the answer (#{inspect(other)})."
end
