defmodule ShoestringWeb.LessonsLive do
  @moduledoc """
  Lessons (iteration 16 B): every repository's lessons, who proposed and who
  approved each, and the person's last word: decide a proposal, reword or
  retire an approved lesson. Also the space lessons take against the limit
  in Settings.
  """
  use ShoestringWeb, :live_view
  on_mount ShoestringWeb.NeedsYou
  alias Shoestring.Lessons
  alias Shoestring.CLI.Commands.Lessons, as: Messages
  alias Shoestring.CLI.WorkLoop

  def mount(_, _, socket),
    do: {:ok, assign(socket, current_scope: nil, page_title: "Lessons")}

  def handle_params(params, _, socket) do
    space = Lessons.space()
    repositories = Enum.map(space.repositories, & &1.repository)
    repository = if params["repository"] in repositories, do: params["repository"]

    {:noreply,
     socket
     |> assign(space: space, repository: repository, focus: params["code"])
     |> load()}
  end

  defp load(socket) do
    lessons = Lessons.list(repository: socket.assigns.repository)
    proposed = Enum.filter(lessons, &(&1.state == "proposed"))
    approved = Enum.filter(lessons, &(&1.state == "approved"))

    assign(socket,
      space: Lessons.space(),
      proposed: proposed,
      approved: approved,
      decided: Enum.filter(lessons, &(&1.state in ~w(rejected retired))),
      forms:
        Map.new(proposed ++ approved, fn lesson ->
          {lesson.code,
           to_form(%{"code" => lesson.code, "text" => lesson.text, "note" => ""}, as: :lesson)}
        end)
    )
  end

  def handle_event("approve", %{"lesson" => %{"code" => code} = attrs}, socket),
    do:
      result(
        socket,
        Lessons.decide(code, "approve", WorkLoop.default_human(), text: attrs["text"]),
        "Approved"
      )

  def handle_event("reject", %{"lesson" => %{"code" => code} = attrs}, socket),
    do:
      result(
        socket,
        Lessons.decide(code, "reject", WorkLoop.default_human(), note: attrs["note"]),
        "Rejected"
      )

  def handle_event("edit", %{"lesson" => %{"code" => code, "text" => text}}, socket),
    do: result(socket, Lessons.edit(code, text, WorkLoop.default_human()), "Saved")

  def handle_event("retire", %{"lesson" => %{"code" => code} = attrs}, socket),
    do: result(socket, Lessons.retire(code, WorkLoop.default_human(), attrs["note"]), "Retired")

  defp result(socket, {:ok, lesson}, verb),
    do: {:noreply, socket |> put_flash(:info, "#{verb} #{lesson.code}") |> load()}

  defp result(socket, {:error, reason}, _verb),
    do: {:noreply, socket |> put_flash(:error, Messages.message(reason)) |> load()}

  defp bytes(n) when n < 1024, do: "#{n} B"
  defp bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KiB"
  defp bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  defp counts(counts),
    do:
      ~w(proposed approved rejected retired)
      |> Enum.filter(&Map.has_key?(counts, &1))
      |> Enum.map_join(", ", &"#{counts[&1]} #{&1}")

  defp source(%{source_kind: "person"} = lesson),
    do: "Your words in session #{lesson.session_id}: “#{lesson.source_quote}”"

  defp source(lesson), do: "Dispatch #{lesson.source_ref} of session #{lesson.session_id}"

  defp proposer(lesson),
    do:
      "Proposed by the #{lesson.proposer_role}" <>
        if(lesson.proposer_agent, do: " (#{lesson.proposer_agent})", else: "")

  defp decider(lesson) do
    cond do
      Lessons.self_approved?(lesson) -> "approved by the coordinator that proposed it"
      is_nil(lesson.decided_by) -> ""
      String.starts_with?(lesson.decided_by, "grant:") -> "approved by the coordinator"
      true -> "approved by #{lesson.decided_by}"
    end
  end

  defp when_cited(%{last_cited_at: nil}), do: "never cited"

  defp when_cited(lesson),
    do: "cited #{lesson.cite_count}×, last #{Calendar.strftime(lesson.last_cited_at, "%Y-%m-%d")}"

  attr :lesson, :map, required: true
  attr :focus, :string, default: nil

  defp about(assigns) do
    ~H"""
    <p id={"lesson-#{@lesson.code}-source"} class="ss-small">{source(@lesson)}</p>
    <p class="ss-small">{proposer(@lesson)}</p>
    <p :if={@lesson.why} class="ss-small">Why: {@lesson.why}</p>
    <p
      :if={@lesson.similar_to not in [nil, []]}
      id={"lesson-#{@lesson.code}-similar"}
      class="ss-small"
    >
      Much like {Enum.join(@lesson.similar_to, ", ")}
    </p>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      product_page="lessons"
      needs_you={@needs_you}
    >
      <div class="ss-heading">
        <div>
          <h1>Lessons</h1>
          <p>
            Rules for work in one repository, shared by every agent there. Agents propose
            them with their source and the coordinator approves them; you see every one and
            may reword, reject or retire any. A worker sees a lesson only when a dispatch cites it.
          </p>
        </div>
      </div>

      <section id="lessons-space" class="ss-panel">
        <div class="ss-row">
          <h2>Space</h2>
          <span id="lessons-total" class="ss-small">
            {@space.count} lessons · {bytes(@space.bytes)} · limit {bytes(@space.limit_bytes)} per repository (Settings)
          </span>
        </div>
        <dl class="ss-roles">
          <div :if={@space.repositories == []} class="ss-row">
            <dt>No lessons yet</dt>
            <dd></dd>
          </div>
          <div
            :for={{repo, index} <- Enum.with_index(@space.repositories)}
            id={"lessons-repository-#{index}"}
            class="ss-row"
          >
            <dt>
              <.link patch={~p"/lessons?#{%{repository: repo.repository}}"}>
                {repo.repository}
              </.link>
            </dt>
            <dd class="ss-small">
              {counts(repo.counts)} · {bytes(repo.bytes)} of {bytes(@space.limit_bytes)}
            </dd>
          </div>
        </dl>
        <p :if={@repository} class="ss-small">
          Showing one repository. <.link patch={~p"/lessons"}>Show all</.link>
        </p>
      </section>

      <h2 class="ss-section">Waiting for the coordinator</h2>
      <p :if={@proposed == []} id="lessons-proposed-empty" class="ss-small">
        Nothing waiting. Workers' proposals, and the coordinator's own that are much like an
        approved lesson, wait here; you may decide them too.
      </p>
      <div id="lessons-proposed" class="ss-grid">
        <article
          :for={lesson <- @proposed}
          id={"lesson-#{lesson.code}"}
          class={["ss-panel", @focus == lesson.code && "ss-focus"]}
        >
          <div class="ss-row">
            <h2>{lesson.code}</h2>
            <span class="ss-small">proposed {Calendar.strftime(lesson.inserted_at, "%Y-%m-%d")}</span>
          </div>
          <p class="ss-small">{lesson.repository_root}</p>
          <.about lesson={lesson} />
          <.form
            for={@forms[lesson.code]}
            id={"approve-#{lesson.code}"}
            phx-submit="approve"
            class="ss-form"
          >
            <.input
              field={@forms[lesson.code][:code]}
              id={"approve-code-#{lesson.code}"}
              type="hidden"
            />
            <.input
              field={@forms[lesson.code][:text]}
              id={"text-#{lesson.code}"}
              type="textarea"
              label="Lesson (reword before approving if you like)"
              rows="3"
              class="ss-input"
            />
            <div class="ss-form-actions">
              <button class="ss-button ss-primary">Approve</button>
            </div>
          </.form>
          <.form
            for={@forms[lesson.code]}
            id={"reject-#{lesson.code}"}
            phx-submit="reject"
            class="ss-form"
          >
            <.input
              field={@forms[lesson.code][:code]}
              id={"reject-code-#{lesson.code}"}
              type="hidden"
            />
            <.input
              field={@forms[lesson.code][:note]}
              id={"note-#{lesson.code}"}
              label="Why reject it (optional)"
              class="ss-input"
            />
            <div class="ss-form-actions">
              <button class="ss-button">Reject</button>
            </div>
          </.form>
        </article>
      </div>

      <h2 class="ss-section">Approved</h2>
      <p :if={@approved == []} class="ss-small">None approved yet.</p>
      <div id="lessons-approved" class="ss-grid">
        <article
          :for={lesson <- @approved}
          id={"lesson-#{lesson.code}"}
          class={["ss-panel", @focus == lesson.code && "ss-focus"]}
        >
          <div class="ss-row">
            <h2>{lesson.code}</h2>
            <span id={"lesson-#{lesson.code}-cited"} class="ss-small">{when_cited(lesson)}</span>
          </div>
          <p class="ss-small">{lesson.repository_root}</p>
          <.about lesson={lesson} />
          <p id={"lesson-#{lesson.code}-decided"} class="ss-small">{decider(lesson)}</p>
          <.form
            for={@forms[lesson.code]}
            id={"edit-#{lesson.code}"}
            phx-submit="edit"
            class="ss-form"
          >
            <.input
              field={@forms[lesson.code][:code]}
              id={"edit-code-#{lesson.code}"}
              type="hidden"
            />
            <.input
              field={@forms[lesson.code][:text]}
              id={"text-#{lesson.code}"}
              type="textarea"
              label="Lesson"
              rows="3"
              class="ss-input"
            />
            <div class="ss-form-actions">
              <button class="ss-button">Save wording</button>
            </div>
          </.form>
          <.form
            for={@forms[lesson.code]}
            id={"retire-#{lesson.code}"}
            phx-submit="retire"
            class="ss-form"
          >
            <.input
              field={@forms[lesson.code][:code]}
              id={"retire-code-#{lesson.code}"}
              type="hidden"
            />
            <.input
              field={@forms[lesson.code][:note]}
              id={"note-#{lesson.code}"}
              label="Why retire it (optional)"
              class="ss-input"
            />
            <div class="ss-form-actions">
              <button class="ss-button">Retire</button>
            </div>
          </.form>
        </article>
      </div>

      <details :if={@decided != []} id="lessons-decided" class="ss-panel">
        <summary>Rejected and retired ({length(@decided)})</summary>
        <ul class="ss-work">
          <li :for={lesson <- @decided} id={"lesson-#{lesson.code}"}>
            <span class="ss-work-title">{lesson.code} · {lesson.state}</span>
            <span class="ss-small">
              {lesson.text}{if(lesson.decision_note, do: " — " <> lesson.decision_note)}
            </span>
          </li>
        </ul>
      </details>
    </Layouts.app>
    """
  end
end
