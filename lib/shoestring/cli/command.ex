defmodule Shoestring.CLI.Command do
  @moduledoc """
  Helpers shared by the `shoestring` command modules in
  `Shoestring.CLI.Commands`.

  Every command module exports `help/0` (its usage text) and
  `run(args, context)`, which returns `:ok` or an exit status and raises
  `Shoestring.CLI.Refusal` for an expected refusal. The context map carries:

  - `:shell` — `Shoestring.CLI.Shell` or a test shell (`info` = stdout data,
    `error` = stderr messages, `prompt`).
  - `:cwd` — the caller's directory; relative paths resolve against it.
  - `:with_repo` — opens the state database for a function.
  - `:service` — checks the running service (`:ok` or `{:error, reason}`).
  - `:start_hint` — how to start the service in this installation.
  """

  alias Shoestring.CLI.Refusal

  @doc "Casts a goal id argument or refuses."
  def goal_id!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> Refusal.refuse!("GOAL must be a goal id; see shoestring goals list")
    end
  end

  @doc "Prints `value` as pretty JSON on stdout."
  def json(context, value), do: context.shell.info(Jason.encode!(value, pretty: true))

  @doc "Expands `path` against the caller's directory."
  def expand(nil, _context), do: nil
  def expand(path, context), do: Path.expand(path, context.cwd)

  @doc "Changeset errors as one `field message; field message` line."
  def errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> flatten()
    |> Enum.join("; ")
  end

  defp flatten(errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} -> Enum.map(flatten(value), &"#{field} #{&1}") end)
  end

  defp flatten(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(message) when is_binary(message), do: [message]
end
