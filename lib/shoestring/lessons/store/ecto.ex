defmodule Shoestring.Lessons.Store.Ecto do
  @moduledoc """
  The default lesson store: Shoestring's database. Retrieval is by shared
  words (three letters or more): `search/3` ranks by how many of the query's
  words a lesson has, and `similar/3` takes lessons whose words overlap by
  half or more (Jaccard).
  """
  @behaviour Shoestring.Lessons.Store

  import Ecto.Query
  alias Shoestring.Lessons.Lesson
  alias Shoestring.Repo

  @similar 0.5

  @impl true
  def insert(%Lesson{} = lesson) do
    lesson
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:origin_key)
    |> Ecto.Changeset.unique_constraint(:code)
    |> Repo.insert()
    |> case do
      {:ok, lesson} ->
        {:ok, lesson}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :origin_key),
          do: {:error, :origin_taken},
          else: {:error, :code_taken}
    end
  end

  @impl true
  def get(code), do: Repo.get_by(Lesson, code: code)

  @impl true
  def list(filters \\ []) do
    Enum.reduce(filters, Lesson, fn
      {:repository, nil}, query -> query
      {:repository, root}, query -> where(query, [l], l.repository_root == ^root)
      {:state, nil}, query -> query
      {:state, states}, query when is_list(states) -> where(query, [l], l.state in ^states)
      {:state, state}, query -> where(query, [l], l.state == ^state)
      {:origin_key, key}, query -> where(query, [l], l.origin_key == ^key)
      {:source_ref, ref}, query -> where(query, [l], l.source_ref == ^ref)
      _other, query -> query
    end)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> Repo.all()
  end

  @impl true
  def transition(%Lesson{} = lesson, from, changes) do
    changes = Map.put(changes, :updated_at, DateTime.utc_now())

    {count, _} =
      from(l in Lesson, where: l.id == ^lesson.id and l.state == ^from)
      |> Repo.update_all(set: Enum.to_list(changes))

    if count == 1, do: {:ok, Repo.get!(Lesson, lesson.id)}, else: :stale
  end

  @impl true
  def search(repository, query, limit) do
    approved = list(repository: repository, state: "approved")

    case words(query || "") do
      [] ->
        Enum.take(approved, limit)

      wanted ->
        wanted = MapSet.new(wanted)

        approved
        |> Enum.map(&{MapSet.size(MapSet.intersection(wanted, MapSet.new(words(&1.text)))), &1})
        |> Enum.filter(fn {score, _} -> score > 0 end)
        |> Enum.sort_by(fn {score, lesson} -> {-score, lesson.code} end)
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 1))
    end
  end

  @impl true
  def similar(repository, text, states) do
    mine = MapSet.new(words(text))

    for lesson <- list(repository: repository, state: states),
        jaccard(mine, MapSet.new(words(lesson.text))) >= @similar,
        do: lesson
  end

  @impl true
  def cite([], _at), do: :ok

  def cite(codes, at) do
    from(l in Lesson, where: l.code in ^codes)
    |> Repo.update_all(inc: [cite_count: 1], set: [last_cited_at: at, updated_at: at])

    :ok
  end

  @impl true
  def space(repository) do
    rows =
      Lesson
      |> then(fn query ->
        if repository, do: where(query, [l], l.repository_root == ^repository), else: query
      end)
      |> group_by([l], [l.repository_root, l.state])
      |> select([l], {
        l.repository_root,
        l.state,
        count(l.id),
        sum(
          fragment(
            "length(CAST(? AS BLOB)) + coalesce(length(CAST(? AS BLOB)), 0) + coalesce(length(CAST(? AS BLOB)), 0) + coalesce(length(CAST(? AS BLOB)), 0)",
            l.text,
            l.source_quote,
            l.why,
            l.decision_note
          )
        )
      })
      |> Repo.all()

    repositories =
      rows
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {root, rows} ->
        %{
          repository: root,
          counts: Map.new(rows, fn {_, state, count, _} -> {state, count} end),
          count: Enum.sum_by(rows, &elem(&1, 2)),
          bytes: Enum.sum_by(rows, &(elem(&1, 3) || 0))
        }
      end)
      |> Enum.sort_by(& &1.repository)

    %{
      repositories: repositories,
      count: Enum.sum_by(repositories, & &1.count),
      bytes: Enum.sum_by(repositories, & &1.bytes)
    }
  end

  defp jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end

  @doc false
  def words(text),
    do:
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) >= 3))
      |> Enum.uniq()
end
