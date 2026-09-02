defmodule Shoestring.Test.MigrationRepo do
  use Ecto.Repo,
    otp_app: :shoestring,
    adapter: Ecto.Adapters.SQLite3
end
