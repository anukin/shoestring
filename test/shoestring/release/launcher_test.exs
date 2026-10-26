defmodule Shoestring.Release.LauncherTest do
  @moduledoc """
  Runs the real `rel/overlays/bin/shoestringctl` against a synthetic release
  root whose runtime is a stub script. No release build, provider or network.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  @launcher Path.expand("../../../rel/overlays/bin/shoestringctl", __DIR__)

  defp release!(dir, manifest_extra) do
    {major, 0} = System.cmd("/usr/bin/sw_vers", ["-productVersion"])
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "lib/shoestring-0.0.0/priv"))
    File.cp!(@launcher, Path.join(dir, "bin/shoestringctl"))
    File.chmod!(Path.join(dir, "bin/shoestringctl"), 0o755)
    runtime = Path.join(dir, "bin/shoestring")

    File.write!(runtime, """
    #!/bin/sh
    echo runtime-ran "$@"
    echo probe="${SHOESTRING_DOCTOR_PROBE_PROVIDERS:-}"
    read -r line && echo stdin="$line"
    exit 0
    """)

    File.chmod!(runtime, 0o755)
    File.write!(Path.join(dir, "lib/shoestring-0.0.0/priv/release_launcher.py"), "")

    manifest =
      Map.merge(%{"tested_macos" => String.trim(major)}, manifest_extra)

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
    Path.join(dir, "bin/shoestringctl")
  end

  defp run(ctl, args), do: System.cmd(ctl, args, stderr_to_stdout: true)

  test "a missing OpenSSL 3 library is named before the runtime starts", %{tmp_dir: dir} do
    missing = Path.join(dir, "absent/libcrypto.3.dylib")
    ctl = release!(dir, %{"openssl_library" => missing})

    for args <- [["doctor"], ["init"], ["version"]] do
      {output, status} = run(ctl, args)
      assert status == 1
      assert output =~ "OpenSSL 3 is a required runtime dependency"
      assert output =~ missing
      assert output =~ "brew install openssl@3"
      refute output =~ "runtime-ran"
    end
  end

  test "a present library, or a manifest from before the check, still runs", %{tmp_dir: dir} do
    library = Path.join(dir, "libcrypto.3.dylib")
    File.write!(library, "")

    for {name, extra} <- [present: %{"openssl_library" => library}, legacy: %{}] do
      ctl = release!(Path.join(dir, Atom.to_string(name)), extra)
      {output, status} = run(ctl, ["doctor"])
      assert status == 0
      assert output =~ "runtime-ran eval"
    end
  end

  test "work commands run the shared CLI with their arguments and an open stdin", %{tmp_dir: dir} do
    ctl = release!(dir, %{})

    for args <- [["do", "fix the bug", "--no-follow"], ["follow", "GOAL"], [], ["help"]] do
      quoted = Enum.map_join([ctl | args], " ", &Shoestring.Shell.argument/1)
      {output, 0} = System.cmd("sh", ["-c", "printf 'y\\n' | " <> quoted], stderr_to_stdout: true)

      expected =
        Enum.join(["runtime-ran eval Shoestring.CLI.Main.main(System.argv())" | args], " ")

      assert output =~ expected <> "\n"

      assert output =~ "stdin=y"
    end
  end

  test "doctor takes --probe-providers and --json in any order, nothing else", %{tmp_dir: dir} do
    ctl = release!(dir, %{})

    for {args, probe} <- [
          {["doctor"], ""},
          {["doctor", "--json"], ""},
          {["doctor", "--probe-providers", "--json"], "1"},
          {["doctor", "--json", "--probe-providers"], "1"}
        ] do
      {output, 0} = run(ctl, args)
      assert output =~ "runtime-ran eval Shoestring.Release.doctor()"
      assert output =~ "probe=#{probe}\n"
      refute output =~ "stdin="
    end

    {output, 2} = run(ctl, ["doctor", "--verbose"])
    assert output == "Usage: shoestring doctor [--probe-providers] [--json]\n"
  end

  test "chat execs the launch script the runtime wrote, or passes its refusal on", %{tmp_dir: dir} do
    ctl = release!(dir, %{})
    runtime = Path.join(dir, "bin/shoestring")

    # The runtime writes a launch script to the --launch-file it was given,
    # or refuses with exit 1 when told to.
    File.write!(runtime, """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case $1 in
        --refuse) echo refused >&2; exit 1 ;;
        --launch-file) printf '#!/bin/sh\\nrm -f -- "$0"\\necho coordinator-started\\n' > "$2"; shift ;;
      esac
      shift
    done
    """)

    {output, 0} = run(ctl, ["chat", "--session", "s1"])
    assert output == "coordinator-started\n"

    {output, 1} = run(ctl, ["chat", "--refuse"])
    assert output == "refused\n"
    refute output =~ "coordinator-started"
  end
end
