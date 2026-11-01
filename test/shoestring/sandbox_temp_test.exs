defmodule Shoestring.SandboxTempTest do
  use ExUnit.Case, async: true

  alias Shoestring.SandboxTemp

  test "a directory it created is removed with its contents" do
    {:ok, dir} = SandboxTemp.create("shoestring-test")
    File.write!(Path.join(dir, "file"), "x")
    assert Path.basename(dir) =~ ~r/\Ashoestring-test-[0-9a-f-]{36}\z/

    assert :ok = SandboxTemp.remove(dir, "shoestring-test")
    refute File.exists?(dir)
    assert :ok = SandboxTemp.remove(nil, "shoestring-test")
  end

  test "anything it could not have created is refused and left in place" do
    {:ok, dir} = SandboxTemp.create("shoestring-test")
    on_exit(fn -> SandboxTemp.remove(dir, "shoestring-test") end)

    # Another prefix, a nested path, a non-UUID name and a symlink.
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove(dir, "shoestring-other")

    nested = Path.join(dir, "shoestring-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(nested)
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove(nested, "shoestring-test")

    plain = Path.join(Path.dirname(dir), "shoestring-test-not-a-uuid")
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove(plain, "shoestring-test")

    link = Path.join(Path.dirname(dir), "shoestring-test-#{Ecto.UUID.generate()}")
    File.ln_s!(nested, link)
    on_exit(fn -> File.rm(link) end)
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove(link, "shoestring-test")

    assert File.dir?(nested)
  end

  test "a short directory is private, under /tmp, and only it can be removed" do
    {:ok, dir} = SandboxTemp.create_short("st")
    on_exit(fn -> SandboxTemp.remove_short(dir, "st") end)
    assert Path.dirname(dir) == SandboxTemp.short_root()
    assert Path.basename(dir) =~ ~r/\Ast-[0-9a-f]{12}\z/
    assert {:ok, %File.Stat{mode: mode}} = File.stat(dir)
    assert Bitwise.band(mode, 0o777) == 0o700

    # Another prefix, a nested path, a non-hex name and a symlink are refused.
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove_short(dir, "sx")
    nested = Path.join(dir, "st-000000000000")
    File.mkdir_p!(nested)
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove_short(nested, "st")

    assert {:error, :not_a_sandbox_temp_dir} =
             SandboxTemp.remove_short(
               Path.join(SandboxTemp.short_root(), "st-nothexnothex"),
               "st"
             )

    link =
      Path.join(
        SandboxTemp.short_root(),
        "st-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.ln_s!(nested, link)
    on_exit(fn -> File.rm(link) end)
    assert {:error, :not_a_sandbox_temp_dir} = SandboxTemp.remove_short(link, "st")
    assert File.dir?(nested)

    assert :ok = SandboxTemp.remove_short(dir, "st")
    refute File.exists?(dir)
    assert :ok = SandboxTemp.remove_short(nil, "st")
  end
end
