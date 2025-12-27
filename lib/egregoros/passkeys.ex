defmodule Egregoros.Passkeys do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.Passkeys.Credential
  alias Egregoros.Repo
  alias Egregoros.User

  def list_credentials(%User{} = user) do
    from(c in Credential, where: c.user_id == ^user.id, order_by: [asc: c.inserted_at])
    |> Repo.all()
  end

  def get_credential(%User{} = user, credential_id)
      when is_binary(credential_id) do
    Repo.get_by(Credential, user_id: user.id, credential_id: credential_id)
  end

  def create_credential(%User{} = user, attrs) when is_map(attrs) do
    %Credential{}
    |> Credential.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert()
  end

  def update_credential(%Credential{} = credential, attrs) when is_map(attrs) do
    credential
    |> Credential.changeset(attrs)
    |> Repo.update()
  end
end

