defmodule Shoestring.Release.NoticesTest do
  @moduledoc """
  A release carries the project license and a notice for every component it
  bundles. Synthetic release, deps, OTP and crate trees; no cargo, no network.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Shoestring.Release.Notices

  @apache Path.expand("../../../rel/licenses/Apache-2.0.txt", __DIR__)

  defp tree!(dir) do
    project = Path.join(dir, "project")
    File.mkdir_p!(Path.join(project, "rel/licenses"))
    File.write!(Path.join(project, "LICENSE"), "MIT License\n\nCopyright (c) Shoestring\n")
    File.cp!(@apache, Path.join(project, "rel/licenses/Apache-2.0.txt"))

    deps = Path.join(dir, "deps")
    hex!(deps, "phoenix", ["MIT"], %{"LICENSE.md" => "MIT phoenix text"})
    hex!(deps, "ecto", ["Apache-2.0"], %{})

    otp = Path.join(dir, "otp/lib")
    File.mkdir_p!(Path.join(otp, "kernel-10.0"))

    elixir_license = Path.join(dir, "elixir/LICENSE")
    File.mkdir_p!(Path.dirname(elixir_license))
    File.write!(elixir_license, "Elixir Apache text")

    release = Path.join(dir, "release")

    for app <- ~w(shoestring-0.2.0 phoenix-1.8.3 ecto-3.13.0 kernel-10.0 elixir-1.19.5 erts-16.2),
        do: File.mkdir_p!(Path.join(release, if(app =~ "erts", do: app, else: "lib/#{app}")))

    crates = Path.join(dir, "crates")
    crate!(crates, "serde", %{"LICENSE-MIT" => "MIT serde text"})
    crate!(crates, "cfg-if", %{})
    crate!(crates, "tempfile", %{"LICENSE-MIT" => "dev only"})

    vendor = Path.join(project, "priv/static/assets/vendor/xterm")
    File.mkdir_p!(vendor)
    File.write!(Path.join(vendor, "LICENSE-xterm"), "MIT xterm text")

    File.write!(
      Path.join(vendor, "provenance.json"),
      Jason.encode!([
        %{
          "package" => "@xterm/xterm",
          "version" => "6.0.0",
          "files_sha256" => %{"xterm.js" => "x", "LICENSE-xterm" => "y"}
        }
      ])
    )

    %{
      release: release,
      project: project,
      opts: [
        project_root: project,
        deps_path: deps,
        otp_lib_dir: otp,
        elixir_license: elixir_license,
        cargo_manifests: ["native/Cargo.toml"],
        cargo_metadata: fn _ -> metadata(crates, "MIT OR Apache-2.0") end,
        version: "0.2.0"
      ]
    }
  end

  defp hex!(deps, name, licenses, files) do
    dir = Path.join(deps, name)
    File.mkdir_p!(dir)
    quoted = Enum.map_join(licenses, ",", &~s(<<"#{&1}">>))
    File.write!(Path.join(dir, "hex_metadata.config"), ~s({<<"licenses">>,[#{quoted}]}.\n))
    for {file, text} <- files, do: File.write!(Path.join(dir, file), text)
  end

  defp crate!(crates, name, files) do
    dir = Path.join(crates, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Cargo.toml"), "")
    for {file, text} <- files, do: File.write!(Path.join(dir, file), text)
  end

  defp metadata(crates, cfg_if_license) do
    package = fn name, license ->
      %{
        "id" => name,
        "name" => name,
        "version" => "1.0.0",
        "license" => license,
        "manifest_path" => Path.join([crates, name, "Cargo.toml"])
      }
    end

    normal = [%{"kind" => nil, "target" => nil}]

    %{
      "packages" => [
        package.("root", nil),
        package.("serde", "MIT OR Apache-2.0"),
        package.("cfg-if", cfg_if_license),
        package.("tempfile", "MIT")
      ],
      "resolve" => %{
        "root" => "root",
        "nodes" => [
          %{
            "id" => "root",
            "deps" => [
              %{"pkg" => "serde", "dep_kinds" => normal},
              %{"pkg" => "tempfile", "dep_kinds" => [%{"kind" => "dev", "target" => nil}]}
            ]
          },
          %{"id" => "serde", "deps" => [%{"pkg" => "cfg-if", "dep_kinds" => normal}]},
          %{"id" => "cfg-if", "deps" => []},
          %{"id" => "tempfile", "deps" => []}
        ]
      }
    }
  end

  test "a release carries LICENSE and a notice for every bundled component", %{tmp_dir: dir} do
    ctx = tree!(dir)
    assert :ok = Notices.write!(ctx.release, ctx.opts)

    assert File.read!(Path.join(ctx.release, "LICENSE")) ==
             File.read!(Path.join(ctx.project, "LICENSE"))

    notices = File.read!(Path.join(ctx.release, "THIRD_PARTY_NOTICES.md"))
    assert notices =~ "Shoestring 0.2.0 is released under the MIT License"

    for row <- [
          "| phoenix | 1.8.3 | Hex | MIT |",
          "| ecto | 3.13.0 | Hex | Apache-2.0 |",
          "| kernel | 10.0 | Erlang/OTP | Apache-2.0 |",
          "| erts | 16.2 | Erlang/OTP | Apache-2.0 |",
          "| elixir | 1.19.5 | Elixir | Apache-2.0 |",
          "| serde | 1.0.0 | crates.io | MIT OR Apache-2.0 |",
          "| cfg-if | 1.0.0 | crates.io | MIT OR Apache-2.0 |",
          "| @xterm/xterm | 6.0.0 | npm (vendored) | see text below |"
        ],
        do: assert(notices =~ row, row)

    for text <- ["MIT phoenix text", "Elixir Apache text", "MIT serde text", "MIT xterm text"],
        do: assert(notices =~ text, text)

    # Shoestring itself and dev-only crates carry no notice.
    refute notices =~ "| shoestring |"
    refute notices =~ "tempfile"

    # The Apache text appears once, for every Apache component without a file.
    apache = File.read!(@apache)
    assert notices |> String.split(String.trim_trailing(apache)) |> length() == 2
  end

  test "a component with neither license text nor an Apache-2.0 option refuses the release",
       %{tmp_dir: dir} do
    ctx = tree!(dir)
    hex!(Path.join(dir, "deps"), "mystery_mit", ["MIT"], %{})
    File.mkdir_p!(Path.join(ctx.release, "lib/mystery_mit-1.0.0"))

    opts =
      Keyword.put(ctx.opts, :cargo_metadata, fn _ ->
        metadata(Path.join(dir, "crates"), "BSD-3-Clause")
      end)

    error = assert_raise ArgumentError, fn -> Notices.write!(ctx.release, opts) end
    assert error.message =~ "cfg-if 1.0.0"
    assert error.message =~ "mystery_mit 1.0.0"
    refute File.exists?(Path.join(ctx.release, "THIRD_PARTY_NOTICES.md"))
    refute File.exists?(Path.join(ctx.release, "LICENSE"))
  end

  test "a bundled application Shoestring cannot attribute refuses the release",
       %{tmp_dir: dir} do
    ctx = tree!(dir)
    File.mkdir_p!(Path.join(ctx.release, "lib/unknown_app-0.1.0"))

    assert {:error, ["unknown_app 0.1.0"]} = Notices.build(ctx.release, ctx.opts)
  end
end
