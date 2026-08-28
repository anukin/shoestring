defmodule Shoestring.HealthTest do
  use Shoestring.DataCase, async: false

  setup do
    previous = System.get_env("SHOESTRING_TEST_STATE_DIR")
    root = Path.join(System.tmp_dir!(), "shoestring-health-#{System.unique_integer([:positive])}")
    System.put_env("SHOESTRING_TEST_STATE_DIR", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("SHOESTRING_TEST_STATE_DIR", previous),
        else: System.delete_env("SHOESTRING_TEST_STATE_DIR")

      File.rm_rf(root)
    end)

    :ok
  end

  test "reports application, repository, and state readiness without vendors" do
    health = Shoestring.Health.check()

    assert health.application == :ok
    assert health.repo == :ok
    assert health.pubsub == :ok
    assert health.state == :ok
    assert Shoestring.Health.ready?()
  end

  test "reports an unwritable state root as not ready" do
    root = Shoestring.State.root()
    File.mkdir_p!(Path.dirname(root))
    File.write!(root, "not a directory")

    health = Shoestring.Health.check()
    assert health.application == :ok
    assert health.repo == :ok
    assert health.pubsub == :ok
    assert health.state == :error
    refute Shoestring.Health.ready?()

    File.rm(root)
  end
end
