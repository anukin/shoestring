defmodule Shoestring.Cobbler.Planner.Fixture do
  @moduledoc "Deterministic, scripted structured inference; no subprocess or network."
  @behaviour Shoestring.Cobbler.Planner.Adapter

  @impl true
  def generate(input, opts) do
    if observer = Keyword.get(opts, :observer), do: send(observer, {:planner_input, input})

    case Enum.at(Keyword.get(opts, :responses, []), input["attempt"] - 1) do
      {:ok, json, tokens} ->
        {:ok, %{json: json, output_tokens: tokens}}

      {:error, code} when is_atom(code) ->
        {:error, code}

      {:await, observer, ref, json, tokens} ->
        send(observer, {:planner_waiting, self(), ref})

        receive do
          {:continue, ^ref} -> {:ok, %{json: json, output_tokens: tokens}}
        end

      _ ->
        {:error, :fixture_exhausted}
    end
  end
end
