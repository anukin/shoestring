defmodule Shoestring.Cobbler.GateSpecTest do
  @moduledoc """
  Versioned gate specifications and configured project gates (iteration 8,
  work package A). Pure: nothing runs.
  """
  # Not async: cases change the :project_gates application config.
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.{GateSpec, PlanGate}

  setup do
    previous = Application.get_env(:shoestring, :project_gates)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :project_gates, previous),
        else: Application.delete_env(:shoestring, :project_gates)
    end)
  end

  test "a built-in gate's specification names everything a green result depends on" do
    ref = %{"gate" => "python_unittest", "test_paths" => ["test/test_calc.py"]}
    assert {:ok, spec} = GateSpec.build(ref, 60_000)

    assert spec == %{
             "schema_version" => 1,
             "gate" => "python_unittest",
             "version" => 1,
             "source" => "builtin",
             "kind" => "test",
             "order" => 4,
             "argv" => ["python3", "-B", "-m", "unittest", "test/test_calc.py"],
             "working_directory" => "worktree",
             "environment" => Shoestring.Cobbler.GateSandbox.environment_names(),
             "timeout_ms" => 60_000,
             "output_limit_bytes" => 65_536,
             "success" => "exit_status_zero",
             "required" => true,
             "artifact" => "combined_output_redacted"
           }

    assert "PATH" in spec["environment"]
    refute Enum.any?(spec["environment"], &String.contains?(&1, "TOKEN"))

    identity = GateSpec.identity(spec)
    assert identity =~ ~r/\Apython_unittest@1:sha256:[0-9a-f]{64}\z/
    assert GateSpec.identity?(identity)

    # Any change to what runs changes the identity.
    {:ok, other} = GateSpec.build(%{ref | "test_paths" => ["test/test_other.py"]}, 60_000)
    refute GateSpec.identity(other) == identity
    {:ok, slower} = GateSpec.build(ref, 90_000)
    refute GateSpec.identity(slower) == identity
  end

  test "gates run cheap kinds first and in plan order within a kind" do
    refs = [
      %{"gate" => "mix_precommit"},
      %{"gate" => "mix_test"},
      %{"gate" => "mix_compile_strict"},
      %{"gate" => "mix_format_check"}
    ]

    assert {:ok, planned} = GateSpec.plan(refs)

    assert Enum.map(planned, fn {ref, _spec} -> ref["gate"] end) ==
             ~w(mix_format_check mix_compile_strict mix_test mix_precommit)

    assert GateSpec.kinds() == ~w(status format compile lint typecheck build test precommit)
  end

  test "a configured project gate is cited by name and resolved from the configuration only" do
    Application.put_env(:shoestring, :project_gates, %{
      "npm_test" => %{argv: ["npm", "test"], kind: "test", timeout_ms: 200_000},
      "ruff" => [argv: ["ruff", "check", "."], kind: "lint", required: false]
    })

    assert {:ok, %{"gate" => "project:npm_test"}} =
             PlanGate.validate(%{"gate" => "project:npm_test"}, :gate)

    assert {:ok, ["npm", "test"]} = PlanGate.argv(%{"gate" => "project:npm_test"})
    assert {:ok, spec} = GateSpec.build(%{"gate" => "project:npm_test"})
    assert spec["source"] == "configuration"
    assert spec["timeout_ms"] == 200_000
    assert spec["required"] == true

    assert {:ok, ruff} = GateSpec.build(%{"gate" => "project:ruff"})
    assert ruff["required"] == false
    assert ruff["order"] < spec["order"]

    # A plan carries a name only: parameters and other spellings are refused.
    assert {:error, _} =
             PlanGate.validate(%{"gate" => "project:npm_test", "argv" => ["sh"]}, :gate)

    assert {:error, _} =
             PlanGate.validate(%{"gate" => "project:npm_test", "test_paths" => ["x"]}, :gate)

    assert {:error, _} = PlanGate.validate(%{"gate" => "project:NPM"}, :gate)
    assert {:error, _} = PlanGate.validate(%{"gate" => "npm_test"}, :gate)
  end

  test "an unconfigured name stays a valid citation but cannot be specified or resolved" do
    Application.put_env(:shoestring, :project_gates, %{})
    ref = %{"gate" => "project:lint"}

    assert {:ok, ^ref} = PlanGate.validate(ref, :gate)
    assert {:error, :project_gate_not_configured} = GateSpec.build(ref)
    assert {:error, _changeset} = PlanGate.argv(ref)

    assert {:error, {^ref, :project_gate_not_configured}} =
             GateSpec.plan([%{"gate" => "mix_test"}, ref])
  end

  test "invalid configuration entries are left out, never half-trusted" do
    Application.put_env(:shoestring, :project_gates, %{
      "ok" => %{argv: ["make", "check"], kind: "build"},
      "abs" => %{argv: ["/bin/sh", "-c", "true"], kind: "test"},
      "relative" => %{argv: ["./run-tests"], kind: "test"},
      "empty" => %{argv: [], kind: "test"},
      "blank_arg" => %{argv: ["make", ""], kind: "test"},
      "nul" => %{argv: ["make", "a" <> <<0>>], kind: "test"},
      "kind" => %{argv: ["make"], kind: "deploy"},
      "slow" => %{argv: ["make"], kind: "test", timeout_ms: 300_001},
      "extra" => %{argv: ["make"], kind: "test", env: %{"X" => "1"}},
      "required" => %{argv: ["make"], kind: "test", required: "no"},
      "Bad-Name" => %{argv: ["make"], kind: "test"},
      "shell" => "make check",
      "secretive" => %{argv: ["make", "password=hunter2"], kind: "test"}
    })

    assert Map.keys(PlanGate.configured()) == ["project:ok"]
  end

  test "all-optional gates are treated as required: optional evidence alone never accepts" do
    Application.put_env(:shoestring, :project_gates, %{
      "a" => %{argv: ["make", "a"], kind: "lint", required: false},
      "b" => %{argv: ["make", "b"], kind: "test", required: false}
    })

    assert {:ok, planned} = GateSpec.plan([%{"gate" => "project:a"}, %{"gate" => "project:b"}])
    assert Enum.all?(planned, fn {_ref, spec} -> spec["required"] end)

    assert {:ok, mixed} = GateSpec.plan([%{"gate" => "project:a"}, %{"gate" => "mix_test"}])
    assert [{_, %{"required" => false}}, {_, %{"required" => true}}] = mixed
  end

  test "an identity must name a known gate and a full digest" do
    refute GateSpec.identity?("mix_test@1:sha256:abc")
    refute GateSpec.identity?("rm_rf@1:sha256:" <> String.duplicate("0", 64))
    assert GateSpec.identity?("project:x@1:sha256:" <> String.duplicate("0", 64))
    refute GateSpec.identity?(nil)
  end
end
