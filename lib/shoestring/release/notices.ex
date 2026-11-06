defmodule Shoestring.Release.Notices do
  @moduledoc """
  The project license and third-party notices a release carries.

  `mix release` writes `LICENSE` and `THIRD_PARTY_NOTICES.md` at the release
  root before it seals the file hashes, so the packaged archive and the
  Homebrew installation both contain them. Every component the release
  bundles is named with its declared license and the license text it ships:

    * Hex packages in the release's `lib/`, from `deps/`;
    * the Erlang/OTP applications and ERTS, and Elixir's own applications;
    * the Rust crates linked into the two native programs (normal
      dependencies of each manifest, for the release target);
    * vendored browser assets recorded in a `provenance.json`.

  A component that ships no license text is accepted only when its declared
  license allows Apache-2.0, whose text names no copyright holder and is
  supplied from `rel/licenses/Apache-2.0.txt`. Any other gap, or a bundled
  application Shoestring cannot attribute, refuses the release: notices are
  never written incomplete.
  """

  @elixir_apps ~w(elixir eex logger iex mix ex_unit)
  @license_file ~r/\A(licen[cs]e|copying|notice)/i
  @target "aarch64-apple-darwin"

  @doc """
  Writes `LICENSE` and `THIRD_PARTY_NOTICES.md` into `release_root`, or raises
  naming every component whose license text could not be found.

  Options (each defaults to this checkout and the running toolchain):
  `:project_root`, `:deps_path`, `:otp_lib_dir`, `:elixir_license`,
  `:cargo_manifests`, `:cargo_metadata` (a function from manifest path to
  decoded `cargo metadata` output), `:vendor_glob` and `:version`.
  """
  def write!(release_root, opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    case build(release_root, Keyword.put(opts, :project_root, project_root)) do
      {:ok, notices} ->
        File.cp!(Path.join(project_root, "LICENSE"), Path.join(release_root, "LICENSE"))
        File.write!(Path.join(release_root, "THIRD_PARTY_NOTICES.md"), notices)
        :ok

      {:error, missing} ->
        raise ArgumentError,
              "Release refused: no license text for " <> Enum.join(missing, ", ")
    end
  end

  @doc "The notices for `release_root`, or `{:error, components}` without license text."
  def build(release_root, opts \\ []) do
    project_root = Keyword.fetch!(opts, :project_root)
    apache = File.read!(Path.join(project_root, "rel/licenses/Apache-2.0.txt"))

    components =
      beam_components(release_root, project_root, opts) ++
        rust_components(project_root, opts) ++ vendored_components(project_root, opts)

    {resolved, missing} =
      Enum.reduce(components, {[], []}, fn component, {ok, missing} ->
        case texts(component) do
          {:ok, texts} -> {[Map.put(component, :texts, texts) | ok], missing}
          :error -> {ok, ["#{component.name} #{component.version}" | missing]}
        end
      end)

    case missing do
      [] -> {:ok, render(Enum.reverse(resolved), apache, Keyword.get(opts, :version))}
      _ -> {:error, Enum.sort(missing)}
    end
  end

  # The release's lib/ holds one NAME-VERSION directory per application.
  defp beam_components(release_root, project_root, opts) do
    deps = Keyword.get(opts, :deps_path, Path.join(project_root, "deps"))
    otp_lib = Keyword.get(opts, :otp_lib_dir, Path.join(to_string(:code.root_dir()), "lib"))

    elixir_license =
      Keyword.get_lazy(opts, :elixir_license, fn ->
        Path.expand("../../LICENSE", to_string(:code.lib_dir(:elixir)))
      end)

    apps =
      release_root
      |> Path.join("lib/*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&split_versioned(Path.basename(&1)))
      |> Enum.reject(fn {name, _} -> name == "shoestring" end)

    erts =
      release_root
      |> Path.join("erts-*")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        {_, version} = split_versioned(Path.basename(path))
        otp("erts", version)
      end)

    erts ++
      Enum.map(apps, fn {name, version} ->
        dep = Path.join(deps, name)

        cond do
          File.regular?(Path.join(dep, "hex_metadata.config")) ->
            %{
              name: name,
              version: version,
              source: "Hex",
              licenses: hex_licenses(dep),
              files: license_files(dep)
            }

          name in @elixir_apps ->
            %{
              name: name,
              version: version,
              source: "Elixir",
              licenses: ["Apache-2.0"],
              files: Enum.filter([elixir_license], &File.regular?/1)
            }

          Path.wildcard(Path.join(otp_lib, "#{name}-*")) != [] ->
            otp(name, version)

          true ->
            %{name: name, version: version, source: "unknown", licenses: [], files: []}
        end
      end)
  end

  defp otp(name, version),
    do: %{name: name, version: version, source: "Erlang/OTP", licenses: ["Apache-2.0"], files: []}

  defp split_versioned(dirname) do
    case Regex.run(~r/\A(.+)-([0-9][^-]*)\z/, dirname) do
      [_, name, version] -> {name, version}
      _ -> {dirname, ""}
    end
  end

  defp hex_licenses(dep) do
    {:ok, terms} = :file.consult(String.to_charlist(Path.join(dep, "hex_metadata.config")))

    case List.keyfind(terms, "licenses", 0) do
      {_, licenses} -> Enum.map(licenses, &to_string/1)
      nil -> []
    end
  end

  defp rust_components(project_root, opts) do
    manifests =
      Keyword.get(opts, :cargo_manifests, [
        Path.join(project_root, "native/terminal_helper/Cargo.toml"),
        Path.join(project_root, "native/chat_client/Cargo.toml")
      ])

    metadata = Keyword.get(opts, :cargo_metadata, &cargo_metadata!/1)

    manifests
    |> Enum.flat_map(&shipped_crates(metadata.(&1)))
    |> Enum.uniq_by(&{&1.name, &1.version})
  end

  defp cargo_metadata!(manifest) do
    args = [
      "metadata",
      "--format-version",
      "1",
      "--locked",
      "--offline",
      "--filter-platform",
      @target,
      "--manifest-path",
      manifest
    ]

    # Offline: the release step has already built (and so fetched) each crate.
    case System.cmd("cargo", args) do
      {output, 0} -> Jason.decode!(output)
      {_, status} -> raise ArgumentError, "cargo metadata failed for #{manifest} (exit #{status})"
    end
  end

  # Normal (not dev or build) dependencies reachable from the manifest's own
  # package. The package itself is Shoestring's and carries no notice.
  defp shipped_crates(%{"packages" => packages, "resolve" => %{"root" => root, "nodes" => nodes}}) do
    packages = Map.new(packages, &{&1["id"], &1})
    nodes = Map.new(nodes, &{&1["id"], &1})

    root
    |> reachable(nodes, MapSet.new())
    |> MapSet.delete(root)
    |> Enum.map(&Map.fetch!(packages, &1))
    |> Enum.map(fn package ->
      dir = Path.dirname(package["manifest_path"])

      %{
        name: package["name"],
        version: package["version"],
        source: "crates.io",
        licenses: spdx_alternatives(package["license"]),
        files: license_files(dir)
      }
    end)
  end

  defp reachable(id, nodes, seen) do
    if MapSet.member?(seen, id) do
      seen
    else
      nodes
      |> Map.get(id, %{})
      |> Map.get("deps", [])
      |> Enum.filter(fn dep -> Enum.any?(dep["dep_kinds"] || [], &is_nil(&1["kind"])) end)
      |> Enum.reduce(MapSet.put(seen, id), &reachable(&1["pkg"], nodes, &2))
    end
  end

  # "MIT OR Apache-2.0", "MIT/Apache-2.0": each alternative, as written.
  defp spdx_alternatives(nil), do: []

  defp spdx_alternatives(expression),
    do: expression |> String.split(~r{\s+OR\s+|\s*/\s*}) |> Enum.map(&String.trim/1)

  defp vendored_components(project_root, opts) do
    glob =
      Keyword.get(
        opts,
        :vendor_glob,
        Path.join(project_root, "priv/static/assets/vendor/*/provenance.json")
      )

    glob
    |> Path.wildcard()
    |> Enum.flat_map(fn provenance ->
      dir = Path.dirname(provenance)

      provenance
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn entry ->
        files =
          entry
          |> Map.get("files_sha256", %{})
          |> Map.keys()
          |> Enum.filter(&Regex.match?(@license_file, &1))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.regular?/1)

        %{
          name: entry["package"],
          version: entry["version"],
          source: "npm (vendored)",
          licenses: [],
          files: files
        }
      end)
    end)
  end

  defp license_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@license_file, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)

      {:error, _} ->
        []
    end
  end

  defp texts(%{source: "unknown"}), do: :error

  defp texts(%{files: [_ | _] = files}),
    do: {:ok, Enum.map(files, &{Path.basename(&1), File.read!(&1)})}

  defp texts(%{licenses: licenses}) do
    if "Apache-2.0" in licenses, do: {:ok, :apache}, else: :error
  end

  defp render(components, apache, version) do
    rows =
      Enum.map(components, fn c ->
        license =
          case c.licenses do
            [] -> "see text below"
            licenses -> Enum.join(licenses, " OR ")
          end

        "| #{c.name} | #{c.version} | #{c.source} | #{license} |"
      end)

    sections =
      Enum.map(components, fn c ->
        body =
          case c.texts do
            :apache ->
              "Licensed under the Apache License, Version 2.0; the package ships no " <>
                "license file of its own. The license text is at the end of this file.\n"

            texts ->
              Enum.map_join(texts, "\n", fn {name, text} ->
                "#{name}:\n\n````text\n#{String.trim_trailing(text)}\n````\n"
              end)
          end

        "### #{c.name} #{c.version}\n\n#{body}"
      end)

    heading = if version, do: "Shoestring #{version}", else: "Shoestring"

    """
    # Third-party notices

    #{heading} is released under the MIT License (see `LICENSE`). This release
    bundles the components below. Each is listed with its declared license and
    the license text it ships. Components licensed under the Apache License 2.0
    that ship no license file of their own are covered by the copy of that
    license at the end of this file.

    | Component | Version | Source | License |
    | --- | --- | --- | --- |
    #{Enum.join(rows, "\n")}

    ## License texts

    #{Enum.join(sections, "\n")}
    ## Apache License 2.0

    ````text
    #{String.trim_trailing(apache)}
    ````
    """
  end
end
