defmodule MiniMe.Repo do
  use Ecto.Repo,
    otp_app: :mini_me,
    adapter: Ecto.Adapters.Postgres
end
