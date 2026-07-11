defmodule Egregoros.MiniApps.AuthRequestTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.MiniApps.AuthRequest
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Repo

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    %{application: application}
  end

  test "builds an authorization URL only for the origin's immutable registration", %{
    application: application
  } do
    params = request_params(application.client_id)

    assert {:ok, request} = AuthRequest.prepare("https://app.example", params)
    assert request.request_id == "auth-1"
    assert request.callback_origin == "https://app.example"

    uri = URI.parse(request.authorization_url)
    assert uri.path == "/oauth/authorize"

    query = URI.decode_query(uri.query)
    assert query["client_id"] == application.client_id
    assert query["redirect_uri"] == "https://app.example/oauth/callback"
    assert query["response_type"] == "code"
    assert query["scope"] == "read write"
    assert query["state"] == String.duplicate("s", 43)
    assert query["code_challenge"] == String.duplicate("c", 43)
    assert query["code_challenge_method"] == "S256"
    refute Map.has_key?(query, "handoff_challenge")
    assert request.relay_state == String.duplicate("s", 43)
  end

  test "rejects a client from another origin and any mutation of the fixed request", %{
    application: application
  } do
    other_application =
      %OAuthApplication{}
      |> OAuthApplication.changeset(%{
        name: "Other",
        redirect_uris: ["https://other.example/callback"],
        scopes: "read write",
        client_id: String.duplicate("o", 32),
        client_secret: String.duplicate("x", 48)
      })
      |> Repo.insert!()

    params = request_params(application.client_id)

    assert {:error, :invalid_client} =
             AuthRequest.prepare(
               "https://app.example",
               %{params | "client_id" => other_application.client_id}
             )

    assert {:error, :invalid_redirect_uri} =
             AuthRequest.prepare(
               "https://app.example",
               %{params | "redirect_uri" => "https://app.example/other"}
             )

    assert {:error, :invalid_scope} =
             AuthRequest.prepare("https://app.example", %{params | "scopes" => ["read"]})

    assert {:error, :invalid_state} =
             AuthRequest.prepare("https://app.example", %{params | "state" => "weak"})

    assert {:error, :pkce_required} =
             AuthRequest.prepare(
               "https://app.example",
               %{params | "code_challenge_method" => "plain"}
             )

    assert {:error, :invalid_handoff_challenge} =
             AuthRequest.prepare(
               "https://app.example",
               %{params | "handoff_challenge" => "short"}
             )
  end

  defp request_params(client_id) do
    %{
      "request_id" => "auth-1",
      "client_id" => client_id,
      "redirect_uri" => "https://app.example/oauth/callback",
      "scopes" => ["read", "write"],
      "state" => String.duplicate("s", 43),
      "code_challenge" => String.duplicate("c", 43),
      "code_challenge_method" => "S256",
      "handoff_challenge" => String.duplicate("h", 43)
    }
  end

  defp manifest_fixture do
    json =
      Jason.encode!(%{
        "version" => "1",
        "name" => "Writer",
        "homeUrl" => "https://app.example/",
        "oauth" => %{
          "redirectUris" => ["https://app.example/oauth/callback"],
          "scopes" => ["read", "write"]
        },
        "capabilities" => ["compose_note"]
      })

    assert {:ok, manifest} =
             Manifest.decode(json, "https://app.example/.well-known/fediverse-miniapp.json")

    manifest
  end
end
