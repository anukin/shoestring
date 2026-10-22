defmodule Shoestring.Release.BootstrapTest do
  use ExUnit.Case, async: true
  alias Shoestring.Release.Bootstrap
  @moduletag :tmp_dir

  test "first initialization creates a private persistent secret without exposing it in status",
       %{tmp_dir: root} do
    assert {:ok, secret} = Bootstrap.endpoint_secret(root)
    assert byte_size(secret) == 88
    assert {:ok, ^secret} = Bootstrap.endpoint_secret(root)
    path = Path.join(root, ".endpoint-secret")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bootstrap.status(root) == "private"
    refute Bootstrap.status(root) =~ secret
  end

  test "operator override is preserved without writing it to state", %{tmp_dir: root} do
    override = String.duplicate("synthetic", 10)
    assert {:ok, ^override} = Bootstrap.endpoint_secret(root, override)
    assert Bootstrap.status(root, override) == "operator_override"
    refute Bootstrap.status(root, override) =~ override
    refute File.exists?(Path.join(root, ".endpoint-secret"))
    assert {:error, :invalid_endpoint_override} = Bootstrap.endpoint_secret(root, "short")
  end

  test "invalid or public existing secret is preserved and refused", %{tmp_dir: root} do
    path = Path.join(root, ".endpoint-secret")
    File.write!(path, "invalid")
    assert {:error, :endpoint_secret_not_private_or_valid} = Bootstrap.endpoint_secret(root)
    assert File.read!(path) == "invalid"
    File.write!(path, Base.encode64(String.duplicate("x", 64)))
    File.chmod!(path, 0o644)
    assert {:error, :endpoint_secret_not_private_or_valid} = Bootstrap.endpoint_secret(root)
    assert Bootstrap.status(root) == "missing_or_invalid"
  end

  test "secret symlinks are refused without changing their targets", %{tmp_dir: root} do
    target = Path.join(root, "target")
    File.write!(target, "retain")
    File.ln_s!(target, Path.join(root, ".endpoint-secret"))
    assert {:error, :endpoint_secret_not_private_or_valid} = Bootstrap.endpoint_secret(root)
    assert File.read!(target) == "retain"
  end
end
