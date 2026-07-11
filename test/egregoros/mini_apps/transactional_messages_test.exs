defmodule Egregoros.MiniApps.TransactionalMessagesTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.DirectMessages
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.NotificationConsents
  alias Egregoros.MiniApps.NotificationAudits
  alias Egregoros.MiniApps.OAuthRegistrations
  alias Egregoros.Notifications
  alias Egregoros.OAuth
  alias Egregoros.OAuth.Application, as: OAuthApplication
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Repo
  alias Egregoros.Users
  alias Egregoros.Workers.IngestActivity

  @origin "https://app.example"
  @actor @origin <> "/ap/actor"

  setup do
    enable_mini_apps()
    {:ok, user} = Users.create_local_user("mini-app-transactional-recipient")
    {:ok, registration} = OAuthRegistrations.register(manifest_fixture())
    activate_mini_app_actor!(@origin)
    application = Repo.get!(OAuthApplication, registration.oauth_application_id)
    authorize!(application, user)
    %{user: user}
  end

  test "accepts one exact direct mention after OAuth and notification consent", %{user: user} do
    assert {:ok, _consent} = NotificationConsents.decide(user.id, @origin, :granted)
    Notifications.subscribe(user.ap_id)
    activity = transactional_create(user.ap_id, "allowed")

    assert {:ok, create} =
             Pipeline.ingest(activity, local: false, inbox_user_ap_id: user.ap_id)

    assert create.ap_id == activity["id"]
    assert %{} = Objects.get_by_ap_id(activity["object"]["id"])
    assert_receive {:notification_created, %{ap_id: note_id}}
    assert note_id == activity["object"]["id"]
    assert Enum.map(DirectMessages.list_for_user(user), & &1.ap_id) == [note_id]
    assert hd(NotificationAudits.list_for_user(user)).event == :delivery_accepted
  end

  test "silently suppresses delivery without consent and after either grant is revoked", %{
    user: user
  } do
    absent = transactional_create(user.ap_id, "absent-consent")
    assert_ignored(absent, user)
    assert hd(NotificationAudits.list_for_user(user)).event == :delivery_suppressed

    assert {:ok, _consent} = NotificationConsents.decide(user.id, @origin, :granted)
    assert :ok = OAuthRegistrations.revoke_user_grant(@origin, user.id)
    revoked_oauth = transactional_create(user.ap_id, "revoked-oauth")
    assert_ignored(revoked_oauth, user)

    application =
      OAuthRegistrations.get_by_origin(@origin)
      |> then(&Repo.get!(OAuthApplication, &1.oauth_application_id))

    authorize!(application, user)
    assert :ok = NotificationConsents.revoke(user.id, @origin)
    revoked_consent = transactional_create(user.ap_id, "revoked-consent")
    assert_ignored(revoked_consent, user)
  end

  test "the inbound worker acknowledges a suppressed message without an oracle", %{user: user} do
    activity = transactional_create(user.ap_id, "worker-acknowledged")

    job = %Oban.Job{
      args: %{"activity" => activity, "inbox_user_ap_id" => user.ap_id}
    }

    assert :ok = IngestActivity.perform(job)
    refute Objects.get_by_ap_id(activity["id"])
    refute Objects.get_by_ap_id(activity["object"]["id"])
  end

  test "silently suppresses malformed transactional notes and shared-inbox delivery", %{
    user: user
  } do
    assert {:ok, _consent} = NotificationConsents.decide(user.id, @origin, :granted)

    public =
      user.ap_id
      |> transactional_create("public-smuggling")
      |> put_in(["object", "cc"], ["https://www.w3.org/ns/activitystreams#Public"])

    assert_ignored(public, user)

    wrong_mention =
      user.ap_id
      |> transactional_create("wrong-mention")
      |> put_in(["object", "tag"], [
        %{"type" => "Mention", "href" => "https://example.invalid/users/other"}
      ])

    assert_ignored(wrong_mention, user)

    multiple_recipients =
      user.ap_id
      |> transactional_create("multiple-recipients")
      |> put_in(["object", "cc"], ["https://remote.example/users/other"])

    assert_ignored(multiple_recipients, user)

    shared = transactional_create(user.ap_id, "shared-inbox")

    assert {:ok, :ignored} =
             Pipeline.ingest(shared,
               local: false,
               inbox_user_ap_id: "https://local.example/actor"
             )

    refute Objects.get_by_ap_id(shared["object"]["id"])

    type_array =
      user.ap_id
      |> transactional_create("type-array-bypass")
      |> Map.put("type", ["Create", "https://example.invalid/Custom"])
      |> put_in(["object", "type"], ["Note", "https://example.invalid/Custom"])
      |> put_in(["object", "tag"], ["malformed"])

    assert_ignored(type_array, user)

    malformed_recipient =
      user.ap_id
      |> transactional_create("malformed-recipient")
      |> put_in(["object", "cc"], [%{"type" => "Person"}])

    assert_ignored(malformed_recipient, user)

    extra_malformed_mention =
      user.ap_id
      |> transactional_create("extra-malformed-mention")
      |> update_in(["object", "tag"], fn tags ->
        tags ++ [%{"type" => "Mention", "name" => "@missing-href"}]
      end)

    assert_ignored(extra_malformed_mention, user)

    bare_note = transactional_create(user.ap_id, "bare-note-bypass")["object"]

    assert {:ok, :ignored} =
             Pipeline.ingest(bare_note, local: false, inbox_user_ap_id: user.ap_id)

    refute Objects.get_by_ap_id(bare_note["id"])

    update = %{
      "id" => @origin <> "/ap/update/update-bypass",
      "type" => "Update",
      "actor" => @actor,
      "to" => [user.ap_id],
      "object" => transactional_create(user.ap_id, "update-bypass")["object"]
    }

    assert {:ok, :ignored} =
             Pipeline.ingest(update, local: false, inbox_user_ap_id: user.ap_id)

    refute Objects.get_by_ap_id(update["object"]["id"])
  end

  test "silently suppresses a declared actor after an operator domain denial", %{user: user} do
    assert {:ok, _consent} = NotificationConsents.decide(user.id, @origin, :granted)

    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> ["app.example"]
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    user.ap_id
    |> transactional_create("operator-denied")
    |> assert_ignored(user)
  end

  test "allows non-individual public notes from the declared app through a shared inbox", %{
    user: user
  } do
    public =
      user.ap_id
      |> transactional_create("public-announcement")
      |> Map.put("to", ["https://www.w3.org/ns/activitystreams#Public"])
      |> Map.put("cc", [@actor <> "/followers"])
      |> put_in(["object", "to"], ["https://www.w3.org/ns/activitystreams#Public"])
      |> put_in(["object", "cc"], [@actor <> "/followers"])
      |> put_in(["object", "tag"], [])

    assert {:ok, _create} = Pipeline.ingest(public, local: false)
    assert %{} = Objects.get_by_ap_id(public["object"]["id"])
    assert DirectMessages.list_for_user(user) == []
  end

  test "does not change ordinary non-mini-app direct mention ingestion", %{user: user} do
    actor = "https://remote.example/users/ordinary"
    activity = transactional_create(user.ap_id, "ordinary", actor)

    assert {:ok, _create} =
             Pipeline.ingest(activity, local: false, inbox_user_ap_id: user.ap_id)

    assert %{} = Objects.get_by_ap_id(activity["object"]["id"])
    assert Enum.map(DirectMessages.list_for_user(user), & &1.ap_id) == [activity["object"]["id"]]
  end

  defp assert_ignored(activity, user) do
    Notifications.subscribe(user.ap_id)

    assert {:ok, :ignored} =
             Pipeline.ingest(activity, local: false, inbox_user_ap_id: user.ap_id)

    refute Objects.get_by_ap_id(activity["id"])
    refute Objects.get_by_ap_id(activity["object"]["id"])
    refute_receive {:notification_created, _}
    assert DirectMessages.list_for_user(user) == []
  end

  defp transactional_create(recipient_ap_id, suffix, actor \\ @actor) do
    note = %{
      "id" => "#{URI.parse(actor).scheme}://#{URI.parse(actor).host}/ap/notes/#{suffix}",
      "type" => "Note",
      "attributedTo" => actor,
      "to" => [recipient_ap_id],
      "cc" => [],
      "content" => "Transaction #{suffix}",
      "tag" => [%{"type" => "Mention", "href" => recipient_ap_id}]
    }

    %{
      "id" => "#{URI.parse(actor).scheme}://#{URI.parse(actor).host}/ap/create/#{suffix}",
      "type" => "Create",
      "actor" => actor,
      "to" => [recipient_ap_id],
      "cc" => [],
      "object" => note
    }
  end

  defp authorize!(application, user) do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert {:ok, code} =
             OAuth.create_authorization_code(
               application,
               user,
               @origin <> "/oauth/callback",
               "read",
               code_challenge: challenge,
               code_challenge_method: "S256"
             )

    assert {:ok, _token} =
             OAuth.exchange_code_for_token(%{
               "grant_type" => "authorization_code",
               "code" => code.code,
               "client_id" => application.client_id,
               "client_secret" => application.client_secret,
               "redirect_uri" => @origin <> "/oauth/callback",
               "code_verifier" => verifier
             })
  end

  defp manifest_fixture do
    attrs = %{
      "version" => "1",
      "name" => "Transactional app",
      "homeUrl" => @origin <> "/",
      "oauth" => %{
        "redirectUris" => [@origin <> "/oauth/callback"],
        "scopes" => ["read"]
      },
      "activityPub" => %{
        "actorUrl" => @actor,
        "publicNotes" => true,
        "transactionalMentions" => true
      },
      "capabilities" => []
    }

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(attrs),
               @origin <> "/.well-known/fediverse-miniapp.json"
             )

    manifest
  end

  defp enable_mini_apps do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)
  end
end
