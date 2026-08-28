import Config

present_env = fn name ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> value
    _ -> nil
  end
end

default_state_dir = fn
  :dev ->
    Path.expand(".shoestring/dev", File.cwd!())

  :test ->
    partition = System.get_env("MIX_TEST_PARTITION", "0")
    Path.join(System.tmp_dir!(), "shoestring-test-#{System.pid()}-#{partition}")

  :prod ->
    case :os.type() do
      {:unix, :darwin} ->
        Path.join(System.user_home!(), "Library/Application Support/Shoestring")

      {:unix, _name} ->
        case present_env.("XDG_STATE_HOME") do
          nil -> Path.join(System.user_home!(), ".local/state/shoestring")
          state_home -> Path.join(state_home, "shoestring")
        end

      _ ->
        Path.join(System.user_home!(), ".shoestring")
    end
end

state_override =
  if config_env() == :test do
    present_env.("SHOESTRING_TEST_STATE_DIR")
  else
    present_env.("SHOESTRING_STATE_DIR")
  end

state_dir = state_override || default_state_dir.(config_env())

config :shoestring,
  environment: config_env(),
  state_dir: state_dir

config :shoestring, Shoestring.Repo, database: Path.join(state_dir, "shoestring.db")

if present_env.("PHX_SERVER") do
  config :shoestring, ShoestringWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    present_env.("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one at build time with: mix phx.gen.secret
      """

  bind_address = present_env.("SHOESTRING_BIND") || "127.0.0.1"

  bind_ip =
    case :inet.parse_address(String.to_charlist(bind_address)) do
      {:ok, address} -> address
      {:error, reason} -> raise "invalid SHOESTRING_BIND #{inspect(bind_address)}: #{reason}"
    end

  port = String.to_integer(present_env.("PORT") || "4000")
  host = present_env.("PHX_HOST") || "localhost"

  config :shoestring, :dns_cluster_query, present_env.("DNS_CLUSTER_QUERY")

  config :shoestring, Shoestring.Repo,
    pool_size: String.to_integer(present_env.("POOL_SIZE") || "5")

  config :shoestring, ShoestringWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: bind_ip, port: port],
    secret_key_base: secret_key_base
end
