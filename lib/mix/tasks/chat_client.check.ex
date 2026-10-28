defmodule Mix.Tasks.ChatClient.Check do
  @shortdoc "Checks the native chat client and installs its development binary"

  @moduledoc """
  Runs `cargo fmt --check`, `clippy -D warnings` and `cargo test` for the
  chat client (`native/chat_client`, iteration 15 package F), against a stub
  channel only, then copies its development binary to
  `priv/bin/shoestring-chat` for `shoestring chat` in this checkout.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    cargo =
      System.find_executable("cargo") || Mix.raise("Rust cargo is required for the chat client")

    manifest = Path.expand("native/chat_client/Cargo.toml")

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
      if status != 0, do: Mix.raise("Chat client check failed (exit #{status})")
    end

    File.mkdir_p!("priv/bin")
    File.cp!("native/chat_client/target/debug/shoestring-chat", "priv/bin/shoestring-chat")
  end
end
