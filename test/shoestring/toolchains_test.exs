defmodule Shoestring.ToolchainsTest do
  use ExUnit.Case, async: false

  alias Shoestring.Toolchains

  @requirement %{"go" => "1.99.1"}

  setup %{tmp_dir: dir} do
    keys = [:state_dir, :toolchain_checksums, :toolchain_test_download, :environment]
    previous = Map.new(keys, &{&1, Application.fetch_env(:shoestring, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:shoestring, key, value)
        {key, :error} -> Application.delete_env(:shoestring, key)
      end)
    end)

    Application.put_env(:shoestring, :state_dir, dir)
    Application.put_env(:shoestring, :environment, :test)
    :ok
  end

  @tag :tmp_dir
  test "validates structured exact versions and rejects path input" do
    assert :ok = Toolchains.validate(@requirement)
    assert {:error, :invalid_go_version} = Toolchains.validate(%{"go" => "1.25.3/../../evil"})

    assert {:error, :invalid_toolchain_requirement} =
             Toolchains.validate(%{"go" => "1.25.3", "url" => "https://evil"})

    assert {:error, :unsupported_go_version} = Toolchains.prepare(@requirement)
  end

  @tag :tmp_dir
  test "verifies, atomically publishes, and reuses a pinned archive", %{tmp_dir: dir} do
    archive = archive!(dir, [{~c"go/bin/go", "fixture executable"}, {~c"go/VERSION", "go1.99.1"}])
    set_checksum(archive)
    stale = Path.join([dir, "toolchains", ".go-stage-stale"])
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "sentinel"), "owned elsewhere")
    assert {:error, :not_cached} = Toolchains.cached_root(@requirement)
    calls = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:shoestring, :toolchain_test_download, fn url ->
      assert url =~
               ~r{\Ahttps://dl\.google\.com/go/go1\.99\.1\.(darwin|linux)-(amd64|arm64)\.tar\.gz\z}

      Agent.update(calls, &(&1 + 1))
      File.read(archive)
    end)

    results =
      1..4
      |> Task.async_stream(fn _ -> Toolchains.prepare(@requirement) end, max_concurrency: 4)
      |> Enum.to_list()

    assert [{:ok, {:ok, root}} | _] = results
    assert Enum.all?(results, &(&1 == {:ok, {:ok, root}}))
    assert Toolchains.install_root(@requirement) == {:ok, root}
    assert File.read!(Path.join(root, "bin/go")) == "fixture executable"
    assert File.read!(Path.join(root, "VERSION")) == "go1.99.1"
    assert Agent.get(calls, & &1) == 1
    assert {:ok, ^root} = Toolchains.cached_root(@requirement)
    assert stages(dir) == [Path.basename(stale)]
    assert File.read!(Path.join(stale, "sentinel")) == "owned elsewhere"
    File.write!(Path.join(root, ".shoestring-sha256"), "wrong")
    assert {:error, :not_cached} = Toolchains.cached_root(@requirement)
    assert Agent.get(calls, & &1) == 1
  end

  @tag :tmp_dir
  test "rejects a mismatched checksum before publication", %{tmp_dir: dir} do
    archive = archive!(dir, [{~c"go/bin/go", "fixture"}])
    set_checksum(archive)

    Application.put_env(:shoestring, :toolchain_test_download, fn _ ->
      {:ok, "different"}
    end)

    assert {:error, :checksum_mismatch} = Toolchains.prepare(@requirement)
    assert {:ok, root} = Toolchains.install_root(@requirement)
    refute File.exists?(root)
    assert stages(dir) == []
  end

  @tag :tmp_dir
  test "rejects traversal entries before extraction", %{tmp_dir: dir} do
    archive = archive!(dir, [{~c"go/bin/go", "fixture"}, {~c"go/../../escape", "bad"}])
    set_checksum(archive)

    Application.put_env(:shoestring, :toolchain_test_download, fn _ ->
      File.read(archive)
    end)

    assert {:error, :invalid_archive} = Toolchains.prepare(@requirement)
    assert {:ok, root} = Toolchains.install_root(@requirement)
    refute File.exists?(root)
    refute File.exists?(Path.join(dir, "escape"))
    assert stages(dir) == []
  end

  defp stages(dir) do
    dir
    |> Path.join("toolchains")
    |> File.ls()
    |> case do
      {:ok, files} -> files
      {:error, :enoent} -> []
    end
    |> Enum.filter(&String.starts_with?(&1, ".go-stage-"))
  end

  defp archive!(dir, entries) do
    path = Path.join(dir, "fixture.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    path
  end

  defp set_checksum(archive) do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
      end

    arch =
      if String.starts_with?(to_string(:erlang.system_info(:system_architecture)), [
           "aarch64",
           "arm64"
         ]), do: "arm64", else: "amd64"

    hash = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    Application.put_env(:shoestring, :toolchain_checksums, %{{"1.99.1", os, arch} => hash})
  end
end
