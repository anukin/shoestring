defmodule Mix.Tasks.ChatClient.Build do
  @shortdoc "Builds and packages the native chat client for this release target"
  use Mix.Task

  @impl true
  def run(_args) do
    cargo =
      System.find_executable("cargo") || Mix.raise("Rust cargo is required for the chat client")

    {output, status} =
      System.cmd(
        cargo,
        ["build", "--release", "--locked", "--manifest-path", "native/chat_client/Cargo.toml"],
        stderr_to_stdout: true
      )

    Mix.shell().info(output)
    if status != 0, do: Mix.raise("Chat client build failed (exit #{status})")
    File.mkdir_p!("priv/bin")
    File.cp!("native/chat_client/target/release/shoestring-chat", "priv/bin/shoestring-chat")
  end
end
