defmodule Egregoros.BadgesTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.BadgeDefinition
  alias Egregoros.Badges
  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Notifications
  alias Egregoros.Repo
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity
  alias EgregorosWeb.Endpoint

  test "issue_badge/2 issues a badge offer to a local user" do
    {:ok, recipient} = Users.create_local_user("badge_issue_local")
    {:ok, badge} = insert_badge_definition("TestDonator")
    {:ok, instance_actor} = InstanceActor.get_actor()

    assert {:ok, %{offer: offer, credential: credential}} =
             Badges.issue_badge("TestDonator", recipient.ap_id)

    assert offer.type == "Offer"
    assert offer.actor == instance_actor.ap_id
    assert offer.object == credential.ap_id

    assert credential.type == "VerifiableCredential"
    assert credential.actor == instance_actor.ap_id
    assert credential.data["issuer"] == instance_actor.ap_id
    assert credential.data["credentialSubject"]["id"] == recipient.ap_id

    assert credential.data["credentialSubject"]["achievement"]["id"] ==
             Endpoint.url() <> "/badges/" <> badge.id

    assert Enum.any?(
             Notifications.list_for_user(recipient, include_offers?: true),
             &(&1.ap_id == offer.ap_id)
           )

    refute_enqueued(worker: DeliverActivity)
  end

  test "issue_badge/2 delivers offers to remote recipients" do
    {:ok, badge} = insert_badge_definition("TestVIP")
    {:ok, instance_actor} = InstanceActor.get_actor()

    remote_ap_id = "https://remote.example/users/alice"
    remote_inbox = "https://remote.example/users/alice/inbox"
    remote_outbox = "https://remote.example/users/alice/outbox"

    expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      assert url == remote_ap_id

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => remote_ap_id,
           "type" => "Person",
           "preferredUsername" => "alice",
           "inbox" => remote_inbox,
           "outbox" => remote_outbox,
           "publicKey" => %{
             "id" => remote_ap_id <> "#main-key",
             "owner" => remote_ap_id,
             "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"
           }
         },
         headers: []
       }}
    end)

    assert {:ok, %{offer: offer, credential: credential}} =
             Badges.issue_badge("TestVIP", remote_ap_id)

    assert offer.actor == instance_actor.ap_id

    assert credential.data["credentialSubject"]["achievement"]["id"] ==
             Endpoint.url() <> "/badges/" <> badge.id

    assert_enqueued(
      worker: DeliverActivity,
      args: %{
        "user_id" => instance_actor.id,
        "inbox_url" => remote_inbox,
        "activity" => %{
          "type" => "Offer",
          "object" => %{"id" => credential.ap_id}
        }
      }
    )
  end

  defp insert_badge_definition(badge_type) do
    %BadgeDefinition{}
    |> BadgeDefinition.changeset(%{
      badge_type: badge_type,
      name: badge_type,
      description: "#{badge_type} badge",
      narrative: "Issued for #{badge_type}",
      disabled: false
    })
    |> Repo.insert()
  end
end
