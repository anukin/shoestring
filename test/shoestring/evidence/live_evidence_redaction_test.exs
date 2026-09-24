defmodule Shoestring.Evidence.LiveEvidenceRedactionTest do
  @moduledoc """
  The committed live-evidence fixtures must stay redacted, including after
  reassembly.

  ## Why this exists

  Redaction was first applied field by field. Codex emits
  `item/agentMessage/delta` frames one fragment at a time, so an absolute
  worktree path — machine shard and run UUID included — was spelled across
  roughly two hundred consecutive events. No single event matched any pattern,
  every per-field scan passed, and the path reassembled perfectly from the
  committed bytes.

  That is the same failure the milestone-04 convention already records in
  another form (`plans/evidence/04-single-elf/README.md` §7: *"prose is inside
  the redaction boundary"*). The general rule is the one this file enforces:
  **a redaction scan must run over the text a reader can reconstruct, not over
  the fields as stored.**

  ## What is checked

  For every committed fixture under the live-evidence directories:

    1. the raw bytes carry no absolute host path, machine shard, credential or
       hidden-reasoning key;
    2. the **reassembled** transcript — every delta fragment and free-text
       detail concatenated in ordinal order — carries none of them either;
    3. every UUID-shaped string belongs to a declared synthetic series, so a
       real identifier cannot hide among the substitutes;
    4. the event counts each file declares match the lines it actually
       contains, so a later edit cannot quietly drop or merge events.

  Hermetic: reads committed files only. No database, no provider, no network.
  """
  use ExUnit.Case, async: true

  @fixture_globs [
    "plans/evidence/05-quota-aware-mvp/fixtures/live/*",
    "plans/evidence/05-quota-aware-mvp/fixtures/live-prod-rerun/*",
    "plans/evidence/04-single-elf/fixtures/harness/*"
  ]

  # Absolute host paths and the macOS per-user temp shard. `/tmp/...` is
  # deliberately allowed: it is not user- or machine-specific, and the
  # milestone-04 convention names it as an acceptable generic root.
  @forbidden_paths [
    ~r{/Users/},
    ~r{/home/[a-z]},
    ~r{/var/folders},
    ~r{/private/var},
    ~r{/private/tmp}
  ]

  @forbidden_secrets [
    ~r/(?i)\bapi[_-]?key\b/,
    ~r/(?i)\bbearer\s+[a-z0-9._-]{8,}/,
    ~r/(?i)\bauthorization:\s*\S/,
    ~r/\bsk-[A-Za-z0-9]{8,}/
  ]

  # Reasoning CONTENT, never reasoning counters. `thinking_tokens` is a frame
  # type the adapter records as telemetry and the convention explicitly
  # permits; a `thinking` block or a scratchpad is what must never land.
  @forbidden_reasoning [
    ~r/"thinking"\s*:/,
    ~r/"reasoning"\s*:/,
    ~r/reasoning_text/,
    ~r/chain_of_thought/,
    ~r/"scratchpad"/
  ]

  # The synthetic series the exporter mints. Anything UUID-shaped outside
  # these is a real identifier that escaped substitution.
  @synthetic_uuid ~r/^(?:01950000-0000-7000-8000|aaaaaaaa-0000-4000-a000|55555555-0000-4000-9000)-\d{12}$/
  @uuid_shaped ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/

  # The protected Observatory goal is a compile-time constant in the
  # repository, not an observation, so it may appear literally.
  @allowed_literal_uuids ["00000000-0000-4000-8000-000000000cb0"]

  describe "committed live evidence" do
    test "there is some to check" do
      assert fixtures() != [], "no live-evidence fixtures found; the globs are stale"
    end

    test "raw bytes carry no absolute host path, credential or hidden reasoning" do
      for {path, body} <- fixtures() do
        refute_patterns(path, body, @forbidden_paths, "absolute host path")
        refute_patterns(path, body, @forbidden_secrets, "credential")
        refute_patterns(path, body, @forbidden_reasoning, "hidden reasoning")
      end
    end

    test "the REASSEMBLED transcript carries none of them either" do
      for {path, body} <- fixtures(), transcript?(body) do
        views = reassembled_views(body)

        # A transcript that declares normalized events must reassemble to
        # something; one that honestly declares none (a launch that failed
        # before any provider output) has nothing to reassemble.
        if declared_count(path, body, "Normalized events") > 0 do
          assert views["raw detail stream"] != "",
                 "#{path}: reassembled to nothing; the parser is stale"
        end

        for {name, text} <- views, text != "" do
          where = "#{path} [#{name}]"

          refute_patterns(where, text, @forbidden_paths, "absolute host path (reassembled)")
          refute_patterns(where, text, @forbidden_secrets, "credential (reassembled)")
          refute_patterns(where, text, @forbidden_reasoning, "hidden reasoning (reassembled)")

          for match <- Regex.scan(@uuid_shaped, text) |> List.flatten() |> Enum.uniq() do
            assert synthetic?(match),
                   "#{where}: reassembled text contains a non-synthetic UUID #{inspect(match)}"
          end
        end
      end
    end

    test "every UUID-shaped string belongs to a declared synthetic series" do
      for {path, body} <- fixtures() do
        for match <- Regex.scan(@uuid_shaped, body) |> List.flatten() |> Enum.uniq() do
          assert synthetic?(match),
                 "#{path}: contains a non-synthetic UUID #{inspect(match)}"
        end
      end
    end

    test "declared event counts match the lines actually present" do
      for {path, body} <- fixtures(), transcript?(body) do
        assert_declared_count(path, body, "Run lifecycle and terminal events")
        assert_declared_count(path, body, "Normalized events")
      end
    end
  end

  # ----------------------------------------------------------------------------

  defp fixtures do
    @fixture_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp transcript?(body), do: String.contains?(body, "## Normalized events")

  # The views a reader can reconstruct, each built CONTIGUOUSLY.
  #
  # Contiguity is the whole point and the easy thing to get wrong: an earlier
  # version of this check concatenated each delta together with the JSON
  # blob that carried it, which put ~80 characters between every pair of
  # fragments and made the spelled-out path unmatchable. It passed against
  # the very fixture that leaked. Each stream below therefore joins ONE kind
  # of fragment with nothing in between.
  defp reassembled_views(body) do
    details =
      body
      |> detail_lines("Normalized events")
      |> Enum.map(fn line ->
        case String.split(line, "\t", parts: 3) do
          [_ordinal, _kind, detail] -> String.trim_leading(detail)
          _other -> ""
        end
      end)

    deltas =
      Enum.map_join(details, fn detail ->
        case Jason.decode(detail) do
          {:ok, map} when is_map(map) ->
            map
            |> Map.get("codex-app-server:delta", "")
            |> to_string()

          _not_json ->
            detail
        end
      end)

    plain = Enum.map_join(details, fn detail -> if json?(detail), do: "", else: detail end)

    %{
      "delta stream" => deltas,
      "plain-text stream" => plain,
      "raw detail stream" => Enum.join(details)
    }
  end

  defp json?(detail), do: match?({:ok, map} when is_map(map), Jason.decode(detail))

  defp declared_count(path, body, heading) do
    case Regex.run(~r/^## #{Regex.escape(heading)}[^(]*\((\d+)\)/m, body) do
      [_, n] -> String.to_integer(n)
      nil -> flunk("#{path}: no declared count for #{inspect(heading)}")
    end
  end

  defp assert_declared_count(path, body, heading) do
    declared = declared_count(path, body, heading)

    actual = length(detail_lines(body, heading))

    assert declared == actual,
           "#{path}: #{heading} declares #{declared} but the block holds #{actual} lines"
  end

  # The lines inside the first fenced block after the given heading.
  defp detail_lines(body, heading) do
    body
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "## " <> heading)))
    |> Enum.drop_while(&(&1 != "```"))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "```"))
  end

  defp synthetic?(uuid),
    do: Regex.match?(@synthetic_uuid, uuid) or uuid in @allowed_literal_uuids

  defp refute_patterns(path, text, patterns, label) do
    for pattern <- patterns do
      case Regex.run(pattern, text, return: :index) do
        nil ->
          :ok

        [{at, len} | _] ->
          flunk("""
          #{path}: #{label} found at offset #{at}

              #{inspect(String.slice(text, max(at - 60, 0), len + 120))}
          """)
      end
    end
  end
end
