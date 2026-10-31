defmodule Shoestring.Lessons.Store do
  @moduledoc """
  Where lessons are kept and how they are found (iteration 16 B). The rules
  of who may propose, approve or retire one live in `Shoestring.Lessons`;
  a store only keeps and retrieves `Shoestring.Lessons.Lesson` values, so a
  different one (a vector index, a shared memory service) can replace the
  default by configuration:

      config :shoestring, :lessons_store, MyStore

  The default, `Shoestring.Lessons.Store.Ecto`, keeps them in Shoestring's
  database and matches by shared words. `search/3` and `similar/3` are the
  retrieval a semantic store would answer by meaning instead.
  """
  alias Shoestring.Lessons.Lesson

  @type code :: String.t()
  @type repository :: String.t()

  @doc "Keeps a new lesson. `{:error, :origin_taken}` when its `origin_key` is already kept."
  @callback insert(Lesson.t()) :: {:ok, Lesson.t()} | {:error, term()}

  @doc "The lesson with `code` (as stored, upper case), or nil."
  @callback get(code()) :: Lesson.t() | nil

  @doc "Lessons, newest first. Filters: `:repository`, `:state` (one or a list), `:origin_key`, `:source_ref`."
  @callback list(keyword()) :: [Lesson.t()]

  @doc "Applies `changes` only if the lesson is still in state `from`."
  @callback transition(Lesson.t(), from :: String.t(), changes :: map()) ::
              {:ok, Lesson.t()} | :stale

  @doc "The repository's approved lessons that best answer `query`, at most `limit`."
  @callback search(repository(), query :: String.t(), limit :: pos_integer()) :: [Lesson.t()]

  @doc "The repository's lessons in `states` that say much the same as `text`."
  @callback similar(repository(), text :: String.t(), states :: [String.t()]) :: [Lesson.t()]

  @doc "Counts one citation of each lesson in `codes` at `at`."
  @callback cite([code()], DateTime.t()) :: :ok

  @doc """
  Space used: `%{repositories: [%{repository, counts, count, bytes}], count, bytes}`,
  for one repository or (nil) all.
  """
  @callback space(repository() | nil) :: map()

  @doc "The configured store."
  def impl, do: Application.get_env(:shoestring, :lessons_store, Shoestring.Lessons.Store.Ecto)
end
