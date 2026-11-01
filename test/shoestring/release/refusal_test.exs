defmodule Shoestring.Release.RefusalTest do
  @moduledoc """
  Release entrypoints run under `bin/shoestring eval`. A refusal must print one
  line and exit 1, never an Elixir stack trace. The halt is injected.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    test = self()

    saved =
      for name <-
            ~w(SHOESTRING_TEST_STATE_DIR SHOESTRING_DIAGNOSTIC_PATH SHOESTRING_DIAGNOSTIC_CONFIRM SHOESTRING_TEXT_PROVIDER SHOESTRING_TEXT_PATH),
          do: {name, System.get_env(name)}

    System.put_env("SHOESTRING_TEST_STATE_DIR", dir)

    Application.put_env(:shoestring, :release_halt, fn status -> send(test, {:halted, status}) end)

    on_exit(fn ->
      Application.delete_env(:shoestring, :release_halt)

      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    %{dir: dir}
  end

  defp refused(fun) do
    stderr = capture_io(:stderr, fn -> assert catch_exit(fun.()) == :release_refused end)
    assert_received {:halted, 1}
    refute stderr =~ "RuntimeError"
    refute stderr =~ "lib/"
    String.trim(stderr)
  end

  test "a diagnostics export refusal names the reason and writes nothing", %{dir: dir} do
    path = Path.join(dir, "bundle.json")
    System.put_env("SHOESTRING_DIAGNOSTIC_PATH", path)
    System.put_env("SHOESTRING_DIAGNOSTIC_CONFIRM", String.duplicate("0", 64))

    assert refused(&Shoestring.Release.diagnostics_export/0) ==
             "Operation refused: existing_database_required"

    refute File.exists?(path)
  end

  test "a busy endpoint tells a person restarting to wait for the old runtime to exit" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    before = Application.fetch_env!(:shoestring, ShoestringWeb.Endpoint)

    Application.put_env(
      :shoestring,
      ShoestringWeb.Endpoint,
      Keyword.put(before, :http, ip: {127, 0, 0, 1}, port: port)
    )

    on_exit(fn ->
      :gen_tcp.close(listener)
      Application.put_env(:shoestring, ShoestringWeb.Endpoint, before)
    end)

    message = refused(&Shoestring.Release.initialize/0)
    assert message =~ "if the old service is stopping, wait for it to exit and retry"
    assert message =~ "otherwise stop it or choose another port"
    assert length(String.split(message, "\n")) == 1
  end

  test "a preview refusal and a text dispatch refusal are one line each", %{dir: dir} do
    assert refused(&Shoestring.Release.diagnostics_preview/0) ==
             "Operation refused: existing_database_required"

    System.put_env("SHOESTRING_TEXT_PROVIDER", "local")
    System.put_env("SHOESTRING_TEXT_PATH", Path.join(dir, "prompt.txt"))

    assert refused(&Shoestring.Release.text_enqueue/0) ==
             "Text dispatch refused; check operator policy and bounded input."
  end
end
