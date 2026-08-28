defmodule Shoestring.StateTest do
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("SHOESTRING_TEST_STATE_DIR")

    test_root =
      Path.join(System.tmp_dir!(), "shoestring-state-#{System.unique_integer([:positive])}")

    System.put_env("SHOESTRING_TEST_STATE_DIR", test_root)

    on_exit(fn ->
      restore_env("SHOESTRING_TEST_STATE_DIR", previous)
      File.rm_rf(test_root)
    end)

    {:ok, root: test_root}
  end

  test "resolves the state root and reserved paths", %{root: root} do
    assert Shoestring.State.root() == root
    assert Shoestring.State.database_path() == Path.join(root, "shoestring.db")
    assert Shoestring.State.path(:artifacts) == Path.join(root, "artifacts")
    assert Shoestring.State.path(:worktrees) == Path.join(root, "worktrees")
    assert Shoestring.State.path(:logs) == Path.join(root, "logs")
    assert Shoestring.State.path(:run) == Path.join(root, "run")
  end

  test "uses the configured default when no environment override is present" do
    System.delete_env("SHOESTRING_TEST_STATE_DIR")
    configured = Application.get_env(:shoestring, :state_dir)

    assert is_binary(configured)
    assert Shoestring.State.root() == configured
  end

  test "explicit environment override takes precedence over application config", %{root: root} do
    configured =
      Path.join(System.tmp_dir!(), "shoestring-configured-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:shoestring, :state_dir)
    Application.put_env(:shoestring, :state_dir, configured)

    on_exit(fn ->
      restore_app_env(:state_dir, previous)
      File.rm_rf(configured)
    end)

    assert Shoestring.State.root() == root
  end

  test "does not leak one override into another resolution" do
    first = Shoestring.State.root()

    second =
      Path.join(System.tmp_dir!(), "shoestring-state-#{System.unique_integer([:positive])}")

    System.put_env("SHOESTRING_TEST_STATE_DIR", second)

    assert first != Shoestring.State.root()
  end

  test "reports an unwritable state root" do
    file_root =
      Path.join(System.tmp_dir!(), "shoestring-state-file-#{System.unique_integer([:positive])}")

    File.write!(file_root, "not a directory")
    System.put_env("SHOESTRING_TEST_STATE_DIR", file_root)

    assert {:error, _reason} = Shoestring.State.ensure_root()

    File.rm(file_root)
  end

  test "ensures a writable root when the path is valid", %{root: root} do
    assert Shoestring.State.ensure_writable_root() == :ok
    assert File.dir?(root)
  end

  test "ignores the production override while running tests", %{root: root} do
    previous = System.get_env("SHOESTRING_STATE_DIR")
    System.put_env("SHOESTRING_STATE_DIR", "/production/state/must-not-be-used")
    on_exit(fn -> restore_env("SHOESTRING_STATE_DIR", previous) end)

    assert Shoestring.State.root() == root
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_app_env(key, value), do: Application.put_env(:shoestring, key, value)
end
