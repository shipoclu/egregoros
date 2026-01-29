defmodule Egregoros.Activities.VerifiableCredentialUpdateTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Activities.Update
  alias Egregoros.BadgeDefinition
  alias Egregoros.Badges
  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Repo
  alias Egregoros.Users

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "accepts an Update that only adds Public to the credential recipients" do
    {:ok, recipient} = Users.create_local_user("vc_update_recipient")
    {:ok, _badge} = insert_badge_definition("UpdatePublic")
    {:ok, instance_actor} = InstanceActor.get_actor()

    assert {:ok, %{credential: credential}} =
             Badges.issue_badge("UpdatePublic", recipient.ap_id)

    assert credential.data["to"] == [recipient.ap_id]

    updated_credential =
      credential.data
      |> Map.put("to", [recipient.ap_id, @public])

    update_activity = Update.build(instance_actor, updated_credential)

    assert {:ok, _update_object} = Pipeline.ingest(update_activity, local: true)

    stored_credential = Objects.get_by_ap_id(credential.ap_id)
    assert @public in stored_credential.data["to"]
  end

  test "rejects an Update that changes credential content beyond adding Public" do
    {:ok, recipient} = Users.create_local_user("vc_update_invalid_recipient")
    {:ok, _badge} = insert_badge_definition("UpdateInvalid")
    {:ok, instance_actor} = InstanceActor.get_actor()

    assert {:ok, %{credential: credential}} =
             Badges.issue_badge("UpdateInvalid", recipient.ap_id)

    mutated_credential =
      credential.data
      |> Map.put("to", [recipient.ap_id, @public])
      |> put_in(["credentialSubject", "achievement", "description"], "Tampered")

    update_activity = Update.build(instance_actor, mutated_credential)

    assert {:error, :invalid} = Pipeline.ingest(update_activity, local: true)

    stored_credential = Objects.get_by_ap_id(credential.ap_id)
    assert stored_credential.data["credentialSubject"]["achievement"]["description"] != "Tampered"
    refute @public in stored_credential.data["to"]
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
