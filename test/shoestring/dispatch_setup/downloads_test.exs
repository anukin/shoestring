defmodule Shoestring.DispatchSetup.DownloadsTest do
  use ExUnit.Case, async: false

  alias Shoestring.DispatchSetup.Downloads

  setup do
    previous_plug = Application.get_env(:shoestring, :dispatch_setup_download_test_plug)
    previous_hosts = Application.get_env(:shoestring, :dispatch_setup_download_hosts)

    destination =
      Path.join(
        System.tmp_dir!(),
        "downloads-test-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(destination)

    on_exit(fn ->
      restore(:dispatch_setup_download_test_plug, previous_plug)
      restore(:dispatch_setup_download_hosts, previous_hosts)
    end)

    %{destination: destination}
  end

  defp restore(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore(key, value), do: Application.put_env(:shoestring, key, value)

  defp asset(url \\ "https://github.com/elixir-lang/elixir/releases/download/v1.0/elixir.zip") do
    %{
      "name" => "elixir.zip",
      "url" => url,
      "sha256" => Base.encode16(:crypto.hash(:sha256, "archive"), case: :lower)
    }
  end

  test "validates exact fields, names, hashes, limits and trusted HTTPS URLs" do
    assert :ok = Downloads.validate([asset()])
    assert :ok = Downloads.validate([asset("https://builds.hex.pm/builds/hex.ez")])

    for url <- [
          "http://github.com/elixir-lang/elixir/releases/download/v1/elixir.zip",
          "https://evil.example/file",
          "https://user@github.com/elixir-lang/elixir/releases/download/v1/file",
          "https://github.com:444/elixir-lang/elixir/releases/download/v1/file",
          "https://github.com/elixir-lang/elixir/releases/download/v1/file?token=x",
          "https://github.com/elixir-lang/elixir/releases/download/v1/file#fragment",
          "https://github.com/elixir-lang/elixir/raw/main/file",
          "https://release-assets.githubusercontent.com/file",
          "https://github.com.evil.example/elixir-lang/elixir/releases/download/v1/file",
          "https://github.com@evil.example/elixir-lang/elixir/releases/download/v1/file",
          "https://github.com/elixir-lang/elixir/releases/download/v1/file?",
          "https://github.com/elixir-lang/elixir/releases/download/v1/file#"
        ] do
      assert {:error, :invalid_downloads} = Downloads.validate([asset(url)])
    end

    for invalid <- [
          Map.put(asset(), "other", 1),
          Map.put(asset(), "name", "../bad"),
          Map.put(asset(), "sha256", String.duplicate("A", 64))
        ] do
      assert {:error, :invalid_downloads} = Downloads.validate([invalid])
    end

    assert {:error, :invalid_downloads} = Downloads.validate([asset(), asset()])
    assert {:error, :invalid_downloads} = Downloads.validate(List.duplicate(asset(), 9))
    Application.put_env(:shoestring, :dispatch_setup_download_hosts, ["downloads.example.org"])
    assert :ok = Downloads.validate([asset("https://downloads.example.org/file")])

    assert {:error, :invalid_downloads} =
             Downloads.validate([asset("https://sub.downloads.example.org/file")])
  end

  test "follows a validated release redirect and writes only verified bytes", %{
    destination: destination
  } do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request_headers, conn.host, conn.req_headers})

      case conn.host do
        "github.com" ->
          Plug.Conn.resp(conn, 302, "")
          |> Plug.Conn.put_resp_header(
            "location",
            "https://release-assets.githubusercontent.com/file?signature=synthetic"
          )

        "release-assets.githubusercontent.com" ->
          Plug.Conn.resp(conn, 200, "archive")
      end
    end

    Application.put_env(:shoestring, :dispatch_setup_download_test_plug, plug)
    assert :ok = Downloads.prepare([asset()], destination)

    for host <- ["github.com", "release-assets.githubusercontent.com"] do
      assert_receive {:request_headers, ^host, headers}
      refute List.keymember?(headers, "authorization", 0)
      refute List.keymember?(headers, "proxy-authorization", 0)
      refute List.keymember?(headers, "cookie", 0)
    end

    assert File.read!(Path.join(destination, "elixir.zip")) == "archive"
  end

  test "rejects untrusted redirects and mismatched checksums without writing the asset", %{
    destination: destination
  } do
    Application.put_env(:shoestring, :dispatch_setup_download_test_plug, fn conn ->
      Plug.Conn.resp(conn, 302, "")
      |> Plug.Conn.put_resp_header("location", "https://evil.example/file")
    end)

    assert {:error, :download_failed} = Downloads.prepare([asset()], destination)
    refute File.exists?(Path.join(destination, "elixir.zip"))

    Application.put_env(:shoestring, :dispatch_setup_download_test_plug, fn conn ->
      Plug.Conn.resp(conn, 200, "wrong")
    end)

    assert {:error, :download_failed} = Downloads.prepare([asset()], destination)
    refute File.exists?(Path.join(destination, "elixir.zip"))
  end
end
