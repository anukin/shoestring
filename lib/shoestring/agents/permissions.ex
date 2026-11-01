defmodule Shoestring.Agents.Permissions do
  @moduledoc """
  What a person lets an implementer agent do beyond its sandbox's defaults:
  folders it may also read (`read_paths`) or write (`write_paths`), and the
  network hosts its commands may reach (`network_hosts`). Empty, the default,
  is nothing beyond the sandbox.

  Each provider's sandbox enforces them differently, so what may be set
  differs (VERIFIED offline 2026-11-01, Claude Code 2.1.316 and Codex
  0.166.0, `plans/evidence/16-long-work/permissions-probe.md`):

    * Claude: folders join the sandbox's `allowRead`/`allowWrite`; hosts are
      its `allowedDomains`, enforced host by host by its network proxy (a host
      not listed was refused; one listed getting through is UNVERIFIED).
    * Codex: folders join the run's permission profile; its network is all
      or nothing (a host list let every host through), so the only host it
      takes is `*`, every host.
    * opencode: its sandbox is fixed; nothing may be set.

  Never your home folder itself or anything above it, nor Shoestring's own
  state (its database, keys and every run's worktree).
  """

  import Ecto.Changeset

  @fields [:read_paths, :write_paths, :network_hosts]
  @max_paths 10
  @max_hosts 20
  @max_bytes 500
  @host ~r/\A(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}\z/

  def fields, do: @fields

  @doc "Form text (one entry per line) into lists; lists pass through."
  def normalize(attrs) when is_map(attrs) do
    Enum.reduce(@fields, attrs, fn field, attrs ->
      Enum.reduce([field, Atom.to_string(field)], attrs, fn key, attrs ->
        case Map.get(attrs, key) do
          text when is_binary(text) ->
            Map.put(
              attrs,
              key,
              text |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
            )

          _ ->
            attrs
        end
      end)
    end)
  end

  @doc "Validates the permission fields of an agent changeset."
  def validate(changeset, opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0) |> Path.expand()
    state = Keyword.get_lazy(opts, :state, &Shoestring.State.root/0) |> Path.expand()
    kind = get_field(changeset, :kind)
    provider = get_field(changeset, :provider)
    set? = Enum.any?(@fields, &(get_field(changeset, &1) not in [nil, []]))

    cond do
      set? and kind != "implementer" ->
        add_error(changeset, :read_paths, "only an implementer's sandbox can be widened")

      set? and provider == "opencode" ->
        add_error(changeset, :read_paths, "opencode's sandbox is fixed; nothing can be added")

      true ->
        changeset
        |> validate_paths(:read_paths, home, state)
        |> validate_paths(:write_paths, home, state)
        |> validate_hosts(provider)
    end
  end

  defp validate_paths(changeset, field, home, state) do
    validate_change(changeset, field, fn ^field, paths ->
      cond do
        length(paths) > @max_paths ->
          [{field, "at most #{@max_paths} folders"}]

        true ->
          Enum.flat_map(paths, &path_error(field, &1, home, state)) |> Enum.take(1)
      end
    end)
  end

  defp path_error(field, path, home, state) do
    cond do
      byte_size(path) > @max_bytes or String.contains?(path, <<0>>) ->
        [{field, "#{String.slice(path, 0, 60)}: too long"}]

      not String.starts_with?(path, "/") or Path.expand(path) != path ->
        [{field, "#{path}: use a full path, like /Users/you/data (no ~, . or ..)"}]

      path == "/" or path == home or String.starts_with?(home, path <> "/") ->
        [{field, "#{path}: not your home folder or anything above it"}]

      path == state or String.starts_with?(path, state <> "/") or
          String.starts_with?(state, path <> "/") ->
        [{field, "#{path}: not Shoestring's own state (its database, keys and worktrees)"}]

      true ->
        []
    end
  end

  defp validate_hosts(changeset, provider) do
    validate_change(changeset, :network_hosts, fn :network_hosts, hosts ->
      cond do
        length(hosts) > @max_hosts ->
          [network_hosts: "at most #{@max_hosts} hosts"]

        provider == "codex" and hosts != ["*"] ->
          [
            network_hosts:
              "Codex cannot limit its network to some hosts: enter * for every host, or leave it empty"
          ]

        provider == "codex" ->
          []

        bad = Enum.find(hosts, &(not Regex.match?(@host, &1))) ->
          [
            network_hosts:
              "#{bad}: a host name like github.com or *.npmjs.org (lowercase, no port)"
          ]

        true ->
          []
      end
    end)
  end

  @doc """
  What a session records of an agent's permissions on its grant and each
  dispatch keeps: nil when nothing was added.
  """
  def snapshot(agent) do
    asks? = field_value(agent, :kind) == "implementer" and field_value(agent, :may_ask) != false

    map =
      for field <- @fields,
          value = field_value(agent, field),
          value not in [nil, []],
          into: %{},
          do: {Atom.to_string(field), value}

    map = if asks?, do: Map.put(map, "may_ask", true), else: map
    if map == %{}, do: nil, else: map
  end

  # A stored `false` is a value, not a missing one.
  defp field_value(%{} = agent, field) do
    case Map.fetch(agent, field) do
      {:ok, value} when not is_nil(value) -> value
      _ -> Map.get(agent, Atom.to_string(field))
    end
  end

  @doc "Plain-language lines for what the additions let the agent do."
  def lines(nil, _provider), do: []

  def lines(permissions, provider) do
    reads = for path <- permissions["read_paths"] || [], do: "Also read #{path}"
    writes = for path <- permissions["write_paths"] || [], do: "Also read and write #{path}"

    hosts =
      case permissions["network_hosts"] || [] do
        [] -> []
        ["*"] when provider == "codex" -> ["Use the network, any host (Codex cannot limit hosts)"]
        hosts -> ["Reach " <> Enum.join(hosts, ", ") <> " from its commands"]
      end

    # Codex and Claude workers ask; opencode's sandbox is fixed.
    asks =
      if permissions["may_ask"] == true and provider in ["codex", "claude"],
        do: [
          "Ask you, while it works, to run one command outside its sandbox; you decide each time"
        ],
        else: []

    reads ++ writes ++ hosts ++ asks
  end
end
