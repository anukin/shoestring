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
end
