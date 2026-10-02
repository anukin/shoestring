defmodule Shoestring.Cobbler.PlannerSafety do
  @moduledoc """
  Backstop scan for unsafe planner directives in proposed plan content.

  `PlanContract` is the primary enforcement: unknown fields (including any
  `command`/`argv`/`shell`-style key) reject a plan before anything else.
  This module covers what strict keys cannot — unsafe *instructions smuggled
  inside free-text values*: reserve or quota bypasses, lifecycle mutations,
  dispatch or lease directives, approval or self-approval claims, destructive
  integration steps, worktree overrides, and embedded command bypasses.

  The scan walks every string value at any depth and reports the first
  offending `{path, directive}` it finds. Matching is deliberately
  phrase-shaped (`bypass the reserve`, not the lone word `reserve`) so
  legitimate task prose about quotas or lifecycles still passes. An unsafe
  proposal is terminal: it is never repaired, never persisted, and never
  retried — the finding names the path and the directive class for the
  operator.
  """

  @directives [
    reserve: [
      ~r/bypass(?:ing)?\s+(?:the\s+)?(?:capacity\s+)?reserves?/i,
      ~r/ignore\s+(?:the\s+)?(?:capacity\s+)?reserves?/i,
      ~r/over\s*ride\s+(?:the\s+)?reserves?/i,
      ~r/reserves?\s+(?:bypass|override)/i,
      ~r/reduc(?:e|ing)\s+(?:the\s+)?reserves?\s+to\s+0/i,
      ~r/quota\s+bypass/i
    ],
    lifecycle: [
      ~r/mutat(?:e|ing)\s+lifecycle/i,
      ~r/force\s+(?:a\s+)?lifecycle\s+transition/i,
      ~r/transition\s+the\s+goal\s+to\s+completed/i,
      ~r/mark\s+(?:the\s+)?tasks?\s+complete\s+without/i
    ],
    dispatch: [
      ~r/dispatch\s+(?:an?\s+)?elf/i,
      ~r/start\s+(?:an?\s+)?elf\s+(?:run|process)/i,
      ~r/grant\s+(?:a\s+|the\s+)?(?:execution\s+)?lease/i,
      ~r/renew\s+(?:the\s+)?lease/i,
      ~r/spawn\s+(?:a\s+)?worker/i
    ],
    approval: [
      ~r/self[\s-]*approv/i,
      ~r/approv(?:e|ing)\s+(?:this\s+|the\s+)?plan\s+(?:on\s+behalf|without\s+human|automatically)/i,
      ~r/approv(?:e|ing)\s+(?:your\s+)?own\s+(?:plan|work)/i,
      ~r/skip\s+human\s+approval/i
    ],
    destructive_integration: [
      ~r/push\s+(?:--force|to\s+main)/i,
      ~r/merge\s+(?:to|into)\s+main/i,
      ~r/delet(?:e|ing)\s+(?:the\s+)?(?:branch|worktree)/i,
      ~r/destroy\s+(?:the\s+)?(?:database|worktree|branch)/i,
      ~r/drop\s+table/i,
      ~r{rm\s+-rf?\s+[/~]},
      ~r/format\s+(?:the\s+)?production/i
    ],
    worktree_override: [
      ~r/worktree\s+override/i,
      ~r/over\s*ride\s+(?:the\s+)?worktree\s+policy/i,
      ~r/operate\s+outside\s+(?:the\s+)?(?:isolated\s+)?worktree/i,
      ~r/modify\s+(?:the\s+)?source\s+checkout\s+directly/i
    ],
    command_bypass: [
      ~r/\$\([^)]*\)/,
      ~r/`[^`]+`/,
      ~r/\brun\s+(?:this\s+)?as\s+shell\b/i,
      ~r/\bexecut(?:e|ing)\s+(?:this\s+|the\s+)?shell\s+command/i,
      ~r/pipe\s+(?:this\s+|the\s+)?to\s+(?:bash|sh)\b/i
    ]
  ]

  @doc "The directive classes this scan reports."
  @spec directives() :: [atom()]
  def directives, do: Keyword.keys(@directives)

  @doc """
  Scans a proposed plan term for unsafe directives.

  Returns `:ok` or `{:error, {:unsafe_proposal, %{path: [...], directive: atom}}}`.
  """
  @spec scan(term()) :: :ok | {:error, {:unsafe_proposal, map()}}
  def scan(term), do: scan_term(term, [])

  defp scan_term(term, path) when is_map(term) do
    Enum.reduce_while(term, :ok, fn {key, value}, :ok ->
      case scan_term(value, path ++ [to_string(key)]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp scan_term(term, path) when is_list(term) do
    term
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case scan_term(value, path ++ [Integer.to_string(index)]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp scan_term(value, path) when is_binary(value) do
    Enum.find_value(@directives, :ok, fn {directive, patterns} ->
      if Enum.any?(patterns, &Regex.match?(&1, value)) do
        {:error, {:unsafe_proposal, %{path: path, directive: directive}}}
      else
        nil
      end
    end)
  end

  defp scan_term(_term, _path), do: :ok
end
