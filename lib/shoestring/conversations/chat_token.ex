defmodule Shoestring.Conversations.ChatToken do
  @moduledoc """
  The token a chat client presents to `/chat/socket` (`docs/chat-channel.md`):
  one per conversation, in `STATE_ROOT/chat/SESSION/chat-token`, readable by
  its owner only. Whoever can read the file is the person.

  The token is never logged, stored in the database or sent back over the
  channel.
  """

  import Bitwise

  @name "chat-token"
  @session ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/

  @doc "The token file of `session`."
  def path(session), do: Path.join([Shoestring.State.root(), "chat", session, @name])

  @doc """
  The session's token, created the first time. A file that is not a private
  regular file holding a token is refused, not replaced, so nothing is
  silently rewritten under the person.
  """
  def ensure(session) do
    with :ok <- session(session) do
      case read(session) do
        {:ok, token} -> {:ok, token}
        {:error, :enoent} -> create(session)
        error -> error
      end
    end
  end

  @doc "`:ok` when `token` is the session's token, else `:error`."
  def verify(session, token) when is_binary(session) and is_binary(token) do
    with :ok <- session(session),
         {:ok, expected} <- read(session),
         true <- Plug.Crypto.secure_compare(expected, token) do
      :ok
    else
      _ -> :error
    end
  end

  def verify(_session, _token), do: :error

  defp session(session) when is_binary(session),
    do: if(Regex.match?(@session, session), do: :ok, else: {:error, :invalid_session})

  defp session(_session), do: {:error, :invalid_session}

  defp read(session) do
    path = path(session)

    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         :ok <- if((mode &&& 0o077) == 0, do: :ok, else: {:error, :token_file_not_private}),
         {:ok, token} <- File.read(path),
         true <- token?(token) || {:error, :invalid_token_file} do
      {:ok, token}
    else
      {:ok, %File.Stat{}} -> {:error, :token_file_not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(session) do
    dir = Path.dirname(path(session))
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    temp = Path.join(dir, ".#{@name}-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- write_private(temp, token),
         :ok <- File.rename(temp, path(session)) do
      {:ok, token}
    else
      error ->
        File.rm(temp)
        error
    end
  end

  # The directory is 0700 before the file exists, so no one else can reach
  # the file even before its own chmod.
  defp write_private(path, token) do
    with :ok <- File.write(path, token, [:exclusive]), do: File.chmod(path, 0o600)
  end

  defp token?(token), do: byte_size(token) == 43 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token)
end
