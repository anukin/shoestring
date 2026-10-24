defmodule Shoestring.Release.ProviderProbe do
  @moduledoc "Explicit metadata-only CLI probes. Raw output is bounded and discarded, never logged or exported."
  alias Shoestring.Elves.PortRunner

  def report(runner \\ &capture/2) do
    Map.new(
      [
        {"claude", ["auth", "status"],
         Shoestring.Harness.ClaudeHeadless.identity().adapter_version},
        {"codex", ["login", "status"],
         Shoestring.Harness.CodexAppServer.identity().adapter_version},
        # `opencode auth list` starts opencode's detached background server,
        # so only the version is read; sign-in is not detectable.
        {"opencode", nil, Shoestring.Harness.OpencodeAcp.identity().adapter_version}
      ],
      fn {name, auth_args, fixture_version} ->
        version =
          case runner.(name, ["--version"]) do
            {:ok, 0, body} when is_binary(body) ->
              body = if String.valid?(body), do: body, else: ""

              case Regex.run(~r/\bv?(\d{1,5}\.\d{1,5}\.\d{1,5})\b/, body) do
                [_, value] -> value
                _ -> nil
              end

            _ ->
              nil
          end

        auth =
          case auth_args && runner.(name, auth_args) do
            nil -> "not_detectable"
            {:ok, 0, _} -> "reported_authenticated"
            {:ok, 1, _} -> "reported_unauthenticated"
            _ -> "unknown"
          end

        {name,
         %{
           "cli_version" => version,
           "wire_fixture_version" => fixture_version,
           "compatibility" =>
             if(version == fixture_version,
               do: "matches_fixture",
               else: "requires_fixture_review"
             ),
           "authentication" => auth
         }}
      end
    )
  end

  def capture(name, args) do
    case PortRunner.spawn([name | args], max_output_bytes: 65_536) do
      {:ok, runner} ->
        result = collect(runner.port, "", System.monotonic_time(:millisecond) + 5_000)
        if match?({:error, _}, result), do: PortRunner.terminate(runner, kill_grace_ms: 100)
        PortRunner.close(runner)
        result

      _ ->
        {:error, :probe_unavailable}
    end
  end

  defp collect(port, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= 65_536 ->
        collect(port, bytes <> chunk, deadline)

      {^port, {:data, _}} ->
        {:error, :probe_oversized}

      {^port, {:exit_status, status}} ->
        {:ok, status, bytes}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :probe_timeout}
    end
  end
end
