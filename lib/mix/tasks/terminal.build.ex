defmodule Mix.Tasks.Terminal.Build do
  @shortdoc "Builds and packages the native PTY helper for this release target"
  use Mix.Task

  @impl true
  def run(_args) do
    cargo =
      System.find_executable("cargo") || Mix.raise("Rust cargo is required for the PTY helper")

    {output, status} =
      System.cmd(
        cargo,
        [
          "build",
          "--release",
          "--locked",
          "--manifest-path",
          "native/terminal_helper/Cargo.toml"
        ],
        stderr_to_stdout: true
      )

    Mix.shell().info(output)
    if status != 0, do: Mix.raise("Native terminal build failed (exit #{status})")
    File.mkdir_p!("priv/bin")

    File.cp!(
      "native/terminal_helper/target/release/shoestring-terminal",
      "priv/bin/shoestring-terminal"
    )
  end
end
