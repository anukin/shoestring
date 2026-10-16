defmodule Shoestring.ShoestringWrapperTest do
  @moduledoc """
  `bin/shoestring` with a stub `mix` first on PATH that records its working
  directory and arguments; no Mix task, provider or network runs. Scratch
  directories are kept.
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

  test "do runs in the checkout with the caller's directory as the repository", ctx do
    assert {0, _, [cwd | args]} =
             wrapper(ctx, ["do", "make add work", "--test", "test/test_calc.py"])

    assert physical(cwd) == physical(@checkout)

    assert ["shoestring.do", "--repo", repo, "make add work", "--test", "test/test_calc.py"] =
             args

    assert physical(repo) == physical(ctx.caller)
  end

  test "other commands pass through; relative --file paths become the caller's", ctx do
    assert {0, _, [_cwd | args]} =
             wrapper(ctx, ["plans", "propose", "G", "--file", "plan.json", "--by", "human:me"])

    assert ["shoestring.plans", "propose", "G", "--file", file, "--by", "human:me"] = args
    assert Path.basename(file) == "plan.json"
    assert physical(Path.dirname(file)) == physical(ctx.caller)

    assert {0, _, [_cwd | ["shoestring.plans", "propose", "G", "--file", "/abs/plan.json"]]} =
             wrapper(ctx, ["plans", "propose", "G", "--file", "/abs/plan.json"])
  end

  test "a symlinked wrapper still finds its checkout", ctx do
    link = Path.join(ctx.dir, "shoestring")
    File.ln_s!(@script, link)
    assert {0, _, [cwd, "shoestring.follow", "G"]} = wrapper(ctx, ["follow", "G"], link)
    assert physical(cwd) == physical(@checkout)
  end

  test "help, unknown commands and no command never run a task", ctx do
    assert {0, help, nil} = wrapper(ctx, ["help"])
    assert help =~ "usage: shoestring COMMAND"
    assert {2, unknown, nil} = wrapper(ctx, ["rm", "-rf"])
    assert unknown =~ "unknown command 'rm'"
    assert {2, _, nil} = wrapper(ctx, [])
    assert {0, _, [_cwd, "help", "shoestring.do"]} = wrapper(ctx, ["do", "--help"])
  end
end
