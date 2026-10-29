defmodule Shoestring.Conversations.ChatTokenTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Shoestring.Conversations.ChatToken

  setup do
    session = "token-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(Path.dirname(ChatToken.path(session))) end)
    %{session: session}
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  test "the token is made once, private to its owner, and verified in either direction", ctx do
    assert {:ok, token} = ChatToken.ensure(ctx.session)
    path = ChatToken.path(ctx.session)

    assert mode(path) == 0o600
    assert mode(Path.dirname(path)) == 0o700
    assert File.read!(path) == token
    assert {:ok, ^token} = ChatToken.ensure(ctx.session)

    assert :ok = ChatToken.verify(ctx.session, token)
    assert :error = ChatToken.verify(ctx.session, token <> "x")
    # The alphabet includes "-", so a fixed substitute could leave the token unchanged.
    {first, rest} = String.split_at(token, 1)
    assert :error = ChatToken.verify(ctx.session, if(first == "-", do: "_", else: "-") <> rest)
    assert :error = ChatToken.verify("other-session", token)
    assert :error = ChatToken.verify(ctx.session, nil)
  end

  test "a token file others can read is refused, not used and not replaced", ctx do
    {:ok, token} = ChatToken.ensure(ctx.session)
    path = ChatToken.path(ctx.session)
    File.chmod!(path, 0o644)

    assert :error = ChatToken.verify(ctx.session, token)
    assert {:error, :token_file_not_private} = ChatToken.ensure(ctx.session)
    assert File.read!(path) == token
  end

  test "a symlink or a malformed file is not a token", ctx do
    {:ok, token} = ChatToken.ensure(ctx.session)
    path = ChatToken.path(ctx.session)
    elsewhere = path <> ".real"
    File.rename!(path, elsewhere)
    File.ln_s!(elsewhere, path)

    assert :error = ChatToken.verify(ctx.session, token)
    assert {:error, :token_file_not_regular} = ChatToken.ensure(ctx.session)

    File.rm!(path)
    File.write!(path, "short")
    File.chmod!(path, 0o600)
    assert :error = ChatToken.verify(ctx.session, "short")
  end

  test "a session that is not a plain name never becomes a path" do
    assert {:error, :invalid_session} = ChatToken.ensure("../escape")
    assert {:error, :invalid_session} = ChatToken.ensure("Upper")
    assert :error = ChatToken.verify("../escape", "x")
  end
end
