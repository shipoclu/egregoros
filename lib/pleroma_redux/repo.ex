defmodule PleromaRedux.Repo do
  use Ecto.Repo,
    otp_app: :pleroma_redux,
    adapter: Ecto.Adapters.Postgres
end
