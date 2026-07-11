defmodule Egregoros.MiniApps.GrantLock do
  @moduledoc false

  alias Egregoros.Repo

  @doc """
  Serializes one user's security-sensitive operations for one mini app.

  Callers must already be inside a `Repo.transaction/1`. The app origin is the
  immutable one-to-one identity of a mini-app OAuth registration. Keeping the
  original advisory-lock key also preserves ordering with notification
  deliveries that started before this boundary was generalized.
  """
  def acquire(user_id, app_origin)
      when is_binary(user_id) and is_binary(app_origin) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["mini-app-notification:" <> user_id <> ":" <> app_origin]
    )

    :ok
  end
end
