defmodule Shoestring.Release.DoctorTest do
  use ExUnit.Case, async: true
  alias Shoestring.Release.Doctor

  test "packaged helper completes a hello without starting a provider" do
    assert {:ok, helper} = Shoestring.Terminal.Launch.helper()
    assert :ok = Doctor.handshake(helper)
  end

  test "missing or wrong helper manifest is refused before launch" do
    assert Doctor.helper_check(nil) == "manifest_required"
    assert Doctor.helper_check(%{"target" => "unsupported"}) == "missing_or_incompatible"
    assert {:error, :helper_incompatible} = Doctor.handshake("/synthetic/absent-helper")
  end

  test "helper hash, application version and protocol must all agree" do
    {:ok, helper} = Shoestring.Terminal.Launch.helper()

    manifest = %{
      "target" => "aarch64-apple-darwin",
      "application_version" => to_string(Application.spec(:shoestring, :vsn)),
      "terminal_protocol" => 1,
      "helper_version" => "0.1.1",
      "helper_sha256" => Base.encode16(:crypto.hash(:sha256, File.read!(helper)), case: :lower)
    }

    if Doctor.supported?(), do: assert(Doctor.helper_check(manifest) == "compatible")

    for {key, value} <- [
          {"helper_sha256", String.duplicate("0", 64)},
          {"application_version", "0.0.0"},
          {"terminal_protocol", 99},
          {"helper_version", "0.0.0"}
        ] do
      assert Doctor.helper_check(Map.put(manifest, key, value)) == "missing_or_incompatible"
    end
  end

  test "agent readiness comes from installation and the explicit probe, never inference" do
    present = fn _ -> "/usr/local/bin/agent" end
    missing = fn _ -> nil end

    probe = fn version, auth -> %{"cli_version" => version, "authentication" => auth} end

    passive = Doctor.agents(nil, present)
    assert passive["claude"]["readiness"] == "not_checked"
    assert passive["codex"]["readiness"] == "not_checked"
    assert passive["claude"]["worker_mode"] == "headless_stream_json"
    assert "2.1.310" in passive["claude"]["tested_versions"]
    assert Doctor.agents(nil, missing)["codex"]["readiness"] == "binary_missing"

    probes = %{
      "claude" => probe.("2.1.310", "reported_authenticated"),
      "codex" => probe.("0.163.0", "reported_unauthenticated")
    }

    report = Doctor.agents(probes, present)
    assert report["claude"]["readiness"] == "ready"
    assert report["claude"]["cli_version"] == "2.1.310"
    assert report["codex"]["readiness"] == "needs_sign_in"

    untested =
      Doctor.agents(%{probes | "claude" => probe.("9.9.9", "reported_authenticated")}, present)

    assert untested["claude"]["readiness"] == "version_untested"

    unknown = Doctor.agents(%{probes | "claude" => probe.(nil, "unknown")}, present)
    assert unknown["claude"]["readiness"] == "unknown"
    assert Doctor.agents(probes, missing)["claude"]["readiness"] == "binary_missing"
  end
end
