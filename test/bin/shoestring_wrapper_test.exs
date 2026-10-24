defmodule Shoestring.ShoestringWrapperTest do
  @moduledoc """
  `bin/shoestring` with a stub `mix` first on PATH that records its working
  directory, `SHOESTRING_CALLER_DIR` and arguments; no Mix task, provider or
  network runs. Argument handling itself is `Shoestring.CLI.Main`'s (see
  `Shoestring.CLI.MainTest`). Scratch directories are kept.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/shoestring", __DIR__)
  @checkout Path.expand("../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "shoestring-wrapper-#{Ecto.UUID.generate()}")
    stub = Path.join(dir, "stub")
    caller = Path.join(dir, "my repo")
    File.mkdir_p!(stub)
    File.mkdir_p!(caller)

    File.write!(Path.join(stub, "mix"), """
    #!/bin/sh
    pwd > "$WRAPPER_OUT"
    printf '%s\\n' "$SHOESTRING_CALLER_DIR" >> "$WRAPPER_OUT"
    for a in "$@"; do printf '%s\\n' "$a" >> "$WRAPPER_OUT"; done
    """)

    File.chmod!(Path.join(stub, "mix"), 0o755)
    %{dir: dir, stub: stub, caller: caller, out: Path.join(dir, "out")}
  end

  defp wrapper(ctx, args, script \\ @script) do
    {output, status} =
      System.cmd("sh", [script | args],
        cd: ctx.caller,
        env: [{"PATH", ctx.stub <> ":" <> System.get_env("PATH")}, {"WRAPPER_OUT", ctx.out}],
        stderr_to_stdout: true
      )

    recorded =
      case File.read(ctx.out) do
        {:ok, text} ->
          File.rm!(ctx.out)
          String.split(text, "\n", trim: true)

        _ ->
          nil
      end

    {status, output, recorded}
  end

  defp physical(path),
    do: path |> then(&System.cmd("pwd", ["-P"], cd: &1)) |> elem(0) |> String.trim()

  test "every command runs `mix shoestring` in the checkout with the caller's directory",
       ctx do
    assert {0, _, [cwd, caller | args]} =
             wrapper(ctx, ["do", "make add work", "--test", "test/test_calc.py"])

    assert physical(cwd) == physical(@checkout)
    assert physical(caller) == physical(ctx.caller)
    assert args == ["shoestring", "do", "make add work", "--test", "test/test_calc.py"]

    assert {0, _, [_cwd, _caller | args]} =
             wrapper(ctx, ["plans", "propose", "G", "--file", "plan.json", "--by", "human:me"])

    assert args == [
             "shoestring",
             "plans",
             "propose",
             "G",
             "--file",
             "plan.json",
             "--by",
             "human:me"
           ]
  end

  test "a symlinked wrapper still finds its checkout", ctx do
    link = Path.join(ctx.dir, "shoestring")
    File.ln_s!(@script, link)

    assert {0, _, [cwd, _caller, "shoestring", "follow", "G"]} =
             wrapper(ctx, ["follow", "G"], link)

    assert physical(cwd) == physical(@checkout)
  end

  test "help, unknown commands and no command go to the shared CLI too", ctx do
    assert {0, _, [_cwd, _caller, "shoestring", "help"]} = wrapper(ctx, ["help"])
    assert {0, _, [_cwd, _caller, "shoestring", "rm", "-rf"]} = wrapper(ctx, ["rm", "-rf"])
    assert {0, _, [_cwd, _caller, "shoestring"]} = wrapper(ctx, [])
  end
end
