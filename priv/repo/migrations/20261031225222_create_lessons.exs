defmodule Shoestring.Repo.Migrations.CreateLessons do
  @moduledoc """
  Lessons (iteration 16 B): short rules for one repository that agents
  propose with their source. A coordinator's own proposal is approved when it
  passes the checks; another agent's waits for the coordinator. The person
  sees every one and may reword, reject or retire it. Dispatches record the
  lessons their brief cites. Each agent says whether it may propose; the
  settings hold the space lessons may take per repository and whether
  `shoestring start` opens the web UI.
  """
  use Ecto.Migration

  def change do
    create table(:lessons, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :repository_root, :string, null: false
      add :text, :text, null: false
      add :state, :string, null: false
      add :source_kind, :string, null: false
      add :source_ref, :string, null: false
      add :source_quote, :text
      add :why, :text
      add :session_id, :string
      add :proposed_by, :string, null: false
      # The proposing agent's job and slug (nil slug: a session without a team).
      add :proposer_role, :string, null: false
      add :proposer_agent, :string
      # Where a worker's proposal was read from, so reading it twice adds nothing.
      add :origin_key, :string
      add :similar_to, :text
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      add :decision_note, :text
      add :retired_by, :string
      add :retired_at, :utc_datetime_usec
      add :cite_count, :integer, null: false, default: 0
      add :last_cited_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lessons, [:code])
    create unique_index(:lessons, [:origin_key])
    create index(:lessons, [:repository_root, :state])

    alter table(:coordinator_dispatches) do
      add :lesson_codes, :text
    end

    alter table(:agents) do
      add :may_propose_lessons, :boolean
    end

    execute "UPDATE agents SET may_propose_lessons = (kind != 'explorer')", ""

    alter table(:agent_settings) do
      add :lessons_space_mb, :integer, null: false, default: 200
      add :open_browser_on_start, :boolean, null: false, default: true
    end
  end
end
