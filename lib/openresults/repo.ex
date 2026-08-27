defmodule OpenResults.Repo do
  use Ecto.Repo,
    otp_app: :openresults,
    adapter: Ecto.Adapters.SQLite3
end
