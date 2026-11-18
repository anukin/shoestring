defmodule Shoestring.DispatchSetupTest do
  use ExUnit.Case, async: true

  alias Shoestring.DispatchSetup

  test "validates the setup envelope" do
    assert :ok = DispatchSetup.validate(%{"script" => "true"})
    assert :ok = DispatchSetup.validate(%{"script" => "echo installed"})

    assert {:error, :invalid_setup} =
             DispatchSetup.validate(%{"script" => "password=synthetic-value"})

    assert {:error, :invalid_setup} = DispatchSetup.validate(%{"script" => ""})
    assert {:error, :invalid_setup} = DispatchSetup.validate(%{"script" => "true", "extra" => 1})
    assert {:error, :invalid_setup} = DispatchSetup.validate(%{"script" => <<0>>})
    assert {:error, :invalid_dispatch} = DispatchSetup.cached_root("", %{"script" => "true"})
  end

  @tag :darwin
  test "setup isolates host files and inherited environment while allowing its own output" do
    id = Ecto.UUID.generate()
    secret = Path.join(System.tmp_dir!(), "setup-secret-#{id}")
    File.write!(secret, "private sentinel")

    script = """
    set -eu
    if /bin/cat '#{secret}' >/dev/null 2>&1; then exit 1; fi
    test -z "${SHOESTRING_TEST_STATE_DIR:-}"
    test -d "$SHOESTRING_SETUP_DOWNLOADS"
    test ! -w "$SHOESTRING_SETUP_DOWNLOADS" || ! touch "$SHOESTRING_SETUP_DOWNLOADS/forbidden" 2>/dev/null
    printf 'installed' > "$SHOESTRING_SETUP_DIR/bin/tool"
    /usr/bin/tar -cf "$SHOESTRING_SETUP_DIR/archive.tar" -C "$SHOESTRING_SETUP_DIR" bin/tool
    /bin/mkdir "$SHOESTRING_SETUP_DIR/extracted"
    /usr/bin/tar -xf "$SHOESTRING_SETUP_DIR/archive.tar" -C "$SHOESTRING_SETUP_DIR/extracted"
    """

    setup = %{"script" => script}

    assert {:error, :not_cached} = DispatchSetup.cached_root(id, setup)
    assert {:ok, root} = DispatchSetup.prepare(id, setup)
    assert File.read!(Path.join(root, "bin/tool")) == "installed"
    assert File.read!(Path.join(root, "extracted/bin/tool")) == "installed"
    assert {:ok, ^root} = DispatchSetup.cached_root(id, setup)
    assert {:ok, ^root} = DispatchSetup.prepare(id, setup)
    assert File.read!(secret) == "private sentinel"
  end

  @tag :darwin
  test "failed scripts and output are not published or returned" do
    id = Ecto.UUID.generate()
    setup = %{"script" => "echo secret-sentinel; exit 1"}
    assert {:error, :setup_failed} = DispatchSetup.prepare(id, setup)
    assert {:error, :not_cached} = DispatchSetup.cached_root(id, setup)
  end

  @tag :darwin
  test "concurrent preparations publish one completed root" do
    id = Ecto.UUID.generate()
    setup = %{"script" => "printf complete > \"$SHOESTRING_SETUP_DIR/bin/tool\""}

    results =
      1..2
      |> Task.async_stream(fn _ -> DispatchSetup.prepare(id, setup) end, timeout: 30_000)
      |> Enum.to_list()

    assert [{:ok, {:ok, root}}, {:ok, {:ok, root}}] = results
    assert File.read!(Path.join(root, "bin/tool")) == "complete"
    assert {:ok, ^root} = DispatchSetup.cached_root(id, setup)
  end
end
