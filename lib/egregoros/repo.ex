defmodule Egregoros.Repo do
  use Ecto.Repo,
    otp_app: :egregoros,
    adapter: Ecto.Adapters.Postgres
end
