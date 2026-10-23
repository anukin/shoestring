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
    File.write!(runtime, "#!/bin/sh\necho runtime-ran \"$@\"\n")
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
end
