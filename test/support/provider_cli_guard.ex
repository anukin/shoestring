defmodule Shoestring.Test.ProviderCliGuard do
  @moduledoc """
  Executable proof that a test spawned no provider CLI (`codex`, `claude`).

  Tests must be hermetic (repository `AGENTS.md`). "It fails closed because
  no CLI is installed here" is not hermetic: on a machine where the CLI IS
  installed, the same test launches it. `adapter_isolation_test.exs` did
  exactly that — it started a real `codex app-server --stdio` on every
  `mix test` wherever `codex` was on `PATH`.

  `install!/0`, called from a synchronous test's `setup`, adds two layers:

    1. **Detection.** Every `:erlang.open_port/2` call in the VM is
       call-traced to a collector process. A spawn whose executable, or whose
       first argument, is a provider CLI is recorded (so a launcher such as
       the Elf's `python3` process-group wrapper is caught too).
       `assert_no_provider_cli_spawned!/1` flushes pending trace messages with
       `:erlang.trace_delivered/1` before it reads the record, so a spawn that
       already happened is always seen: no polling, no sleeps.
    2. **Containment.** Shim `codex` and `claude` executables are put first on
       `PATH`. A spawn this guard exists to catch runs the shim, which exits
       non-zero, never the real CLI.

  Only for `async: false` tests: tracing and `PATH` are VM-global. Both are
  restored on exit.
  """

  import ExUnit.Assertions

  @providers ~w(codex claude)

  @type t :: %{collector: pid(), shim_dir: String.t()}

  @spec install!() :: t()
  def install! do
    shim_dir =
      Path.join(System.tmp_dir!(), "provider-cli-guard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(shim_dir)

    for provider <- @providers do
      path = Path.join(shim_dir, provider)

      File.write!(
        path,
        "#!/bin/sh\necho 'provider CLI shim: #{provider} must not run in tests' >&2\nexit 97\n"
      )

      File.chmod!(path, 0o755)
    end

    previous_path = System.get_env("PATH")
    System.put_env("PATH", shim_dir <> ":" <> (previous_path || ""))

    collector = spawn(fn -> collect([]) end)
    :erlang.trace(:all, true, [:call, {:tracer, collector}])
    :erlang.trace_pattern({:erlang, :open_port, 2}, true, [:global])

    ExUnit.Callbacks.on_exit(fn ->
      :erlang.trace_pattern({:erlang, :open_port, 2}, false, [:global])
      :erlang.trace(:all, false, [:call])
      Process.exit(collector, :kill)
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
      File.rm_rf!(shim_dir)
    end)

    %{collector: collector, shim_dir: shim_dir}
  end

  @doc "The provider-CLI spawns recorded so far, oldest first."
  @spec provider_spawns(t()) :: [map()]
  def provider_spawns(%{collector: collector}) do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    end

    send(collector, {:spawns, self()})

    receive do
      {:provider_spawns, spawns} -> Enum.reverse(spawns)
    end
  end

  @spec assert_no_provider_cli_spawned!(t()) :: :ok
  def assert_no_provider_cli_spawned!(guard) do
    spawns = provider_spawns(guard)

    assert spawns == [],
           "a provider CLI was spawned during a hermetic test: #{inspect(spawns)}"

    :ok
  end

  defp collect(spawns) do
    receive do
      {:trace, pid, :call, {:erlang, :open_port, [name, opts]}} ->
        case provider_spawn(name, opts) do
          nil -> collect(spawns)
          spawn -> collect([Map.put(spawn, :pid, pid) | spawns])
        end

      {:spawns, from} ->
        send(from, {:provider_spawns, spawns})
        collect(spawns)

      _other ->
        collect(spawns)
    end
  end

  defp provider_spawn({:spawn_executable, executable}, opts) do
    args = opts |> List.wrap() |> Keyword.get(:args, []) |> Enum.map(&to_string/1)
    candidates = [to_string(executable) | Enum.take(args, 1)]

    if Enum.any?(candidates, &provider?/1),
      do: %{executable: to_string(executable), args: args}
  end

  defp provider_spawn({:spawn, command}, _opts) do
    first = command |> to_string() |> String.split() |> List.first("")
    if provider?(first), do: %{command: to_string(command)}
  end

  defp provider_spawn(_name, _opts), do: nil

  defp provider?(path), do: Path.basename(path) in @providers
end
