defmodule Egregoros.OAuth.Application do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, FlakeId.Ecto.Type, autogenerate: true}
  @foreign_key_type FlakeId.Ecto.Type

  @required_fields ~w(name redirect_uris client_id client_secret)a
  @optional_fields ~w(website scopes)a

  schema "oauth_applications" do
    field :name, :string
    field :website, :string
    field :redirect_uris, {:array, :string}, default: []
    field :scopes, :string, default: ""
    field :client_id, :string
    field :client_secret, :string

    field :client_type, Ecto.Enum,
      values: [:confidential, :public_mini_app],
      default: :confidential

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields ++ [:client_type])
    |> validate_length(:name, max: 200)
    |> validate_length(:client_id, min: 10, max: 200)
    |> validate_length(:client_secret, min: 10, max: 200)
    |> validate_redirect_uris()
    |> unique_constraint(:client_id)
  end

  defp validate_redirect_uris(changeset) do
    changeset =
      validate_change(changeset, :redirect_uris, fn :redirect_uris, value ->
        cond do
          not is_list(value) ->
            [redirect_uris: "must be a list"]

          Enum.any?(value, &(&1 == nil)) ->
            [redirect_uris: "must not contain null values"]

          Enum.any?(value, &(is_binary(&1) and String.trim(&1) == "")) ->
            [redirect_uris: "must not contain empty values"]

          Enum.any?(value, &(not valid_redirect_uri?(&1))) ->
            [redirect_uris: "contains an unsafe or invalid URI"]

          true ->
            []
        end
      end)

    if get_field(changeset, :redirect_uris) == [] do
      add_error(changeset, :redirect_uris, "must contain at least one URI")
    else
      changeset
    end
  end

  defp valid_redirect_uri?("urn:ietf:wg:oauth:2.0:oob"), do: true

  defp valid_redirect_uri?(value) when is_binary(value) do
    if String.match?(value, ~r/[\x00-\x1F\x7F]/) do
      false
    else
      case URI.parse(value) do
        %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
        when is_binary(host) and host != "" ->
          true

        %URI{scheme: "http", host: host, userinfo: nil, fragment: nil}
        when host in ["localhost", "127.0.0.1", "::1"] ->
          true

        %URI{scheme: scheme, host: nil, userinfo: nil, fragment: nil, path: "/" <> _}
        when is_binary(scheme) ->
          String.contains?(scheme, ".") and
            String.match?(scheme, ~r/^[a-z][a-z0-9+.-]*$/)

        _ ->
          false
      end
    end
  end

  defp valid_redirect_uri?(_value), do: false
end
