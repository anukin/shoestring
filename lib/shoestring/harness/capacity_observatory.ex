defmodule Shoestring.Harness.CapacityObservatory do
  @moduledoc """
  Alias and convenience boundary for `Shoestring.Harness.Observatory`.
  """

  defdelegate observatory_goal_id(), to: Shoestring.Harness.Observatory
  defdelegate observatory_owner_id(), to: Shoestring.Harness.Observatory
  defdelegate observatory_title(), to: Shoestring.Harness.Observatory
  defdelegate observatory_description(), to: Shoestring.Harness.Observatory
  defdelegate observatory_status(), to: Shoestring.Harness.Observatory
  defdelegate observatory_goal?(goal_or_id), to: Shoestring.Harness.Observatory

  defdelegate ensure_provisioned(), to: Shoestring.Harness.Observatory
  defdelegate ensure_provisioned(opts), to: Shoestring.Harness.Observatory

  defdelegate ingest(snapshot), to: Shoestring.Harness.Observatory
  defdelegate ingest(snapshot, opts), to: Shoestring.Harness.Observatory

  defdelegate latest_observation(provider_id, mode, scope), to: Shoestring.Harness.Observatory

  defdelegate latest_observation(provider_id, mode, scope, opts),
    to: Shoestring.Harness.Observatory

  defdelegate get_latest_observation(provider_id, mode, scope), to: Shoestring.Harness.Observatory

  defdelegate get_latest_observation(provider_id, mode, scope, opts),
    to: Shoestring.Harness.Observatory

  defdelegate latest_observations(), to: Shoestring.Harness.Observatory
  defdelegate latest_observations(opts), to: Shoestring.Harness.Observatory

  defdelegate observation_summary(snapshot), to: Shoestring.Harness.Observatory
  defdelegate observation_summary(snapshot, opts), to: Shoestring.Harness.Observatory

  defdelegate deduplication_key(snapshot), to: Shoestring.Harness.Observatory
  defdelegate equivalent?(a, b), to: Shoestring.Harness.Observatory
  defdelegate equivalent?(a, b, now), to: Shoestring.Harness.Observatory
  defdelegate record_to_snapshot(record), to: Shoestring.Harness.Observatory
  defdelegate record_to_snapshot(record, opts), to: Shoestring.Harness.Observatory
end
