defmodule Shoestring.Harness.OpencodeAcpContractTest do
  @moduledoc """
  Shoestring.Harness.OpencodeAcp against the shared ContractSuite on its
  simulated paths, like the other adapters.
  """
  use Shoestring.Harness.ContractSuite,
    adapter: Shoestring.Harness.OpencodeAcp,
    config: %{}
end

defmodule Shoestring.Harness.OpencodeAcpStdioContractTest do
  @moduledoc """
  The same ContractSuite driven over real stdio against the scripted
  `opencode acp` stand-in (`test/support/fake_opencode_acp.py`): the live
  session path, with no real opencode binary and no network.
  """
  use Shoestring.Harness.ContractSuite,
    adapter: Shoestring.Harness.OpencodeAcp,
    config: %{
      live: true,
      executable: System.find_executable("python3"),
      args: [Path.expand("../../support/fake_opencode_acp.py", __DIR__)],
      workdir: System.tmp_dir!(),
      model: "opencode/test-model",
      env: [{"FAKE_OPENCODE_SCENARIO", "complete"}],
      await_completion: fn identity ->
        {:ok, _} =
          Shoestring.Test.ElvesHelpers.wait_until(fn ->
            {:ok, events} = Shoestring.Harness.OpencodeAcp.stream(identity, %{live: true})
            Enum.any?(events, &(&1.kind == :result))
          end)
      end
    }
end
