defmodule Mix.Tasks.Terminal.Check do
  @shortdoc "Checks the native PTY helper and installs its development binary"
  use Mix.Task

  @impl true
  def run(_args) do
    cargo =
      System.find_executable("cargo") || Mix.raise("Rust cargo is required for the PTY helper")

    manifest = Path.expand("native/terminal_helper/Cargo.toml")

    for args <- [
          ["fmt", "--manifest-path", manifest, "--", "--check"],
          [
            "clippy",
            "--locked",
            "--manifest-path",
            manifest,
            "--all-targets",
            "--",
            "-D",
            "warnings"
          ],
          ["test", "--locked", "--manifest-path", manifest]
        ] do
      {output, status} = System.cmd(cargo, args, stderr_to_stdout: true)
      Mix.shell().info(output)
      if status != 0, do: Mix.raise("Native terminal check failed (exit #{status})")
    end

    File.mkdir_p!("priv/bin")

    File.cp!(
      "native/terminal_helper/target/debug/shoestring-terminal",
      "priv/bin/shoestring-terminal"
    )
  end
end
