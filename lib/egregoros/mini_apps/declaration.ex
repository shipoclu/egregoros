defmodule Egregoros.MiniApps.Declaration do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}

  schema "mini_app_declarations" do
    field :app_origin, :string
    field :oauth_redirect_uris, {:array, :string}, default: []
    field :oauth_scopes, {:array, :string}, default: []
    field :capabilities, {:array, :string}, default: []
    field :wallet_evm_enabled, :boolean, default: false
    field :wallet_evm_required, :boolean, default: false
    field :wallet_evm_required_chains, {:array, :string}, default: []
    field :manifest_fingerprint, :binary
    field :declared_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(declaration, attrs) do
    declaration
    |> cast(attrs, [
      :app_origin,
      :oauth_redirect_uris,
      :oauth_scopes,
      :capabilities,
      :wallet_evm_enabled,
      :wallet_evm_required,
      :wallet_evm_required_chains,
      :manifest_fingerprint,
      :declared_at
    ])
    |> validate_required([:app_origin, :manifest_fingerprint, :declared_at])
    |> validate_length(:app_origin, max: 255)
    |> unique_constraint(:app_origin)
  end
end
