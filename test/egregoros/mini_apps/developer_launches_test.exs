defmodule Egregoros.MiniApps.DeveloperLaunchesTest do
  use Egregoros.DataCase, async: false

  alias Egregoros.MiniApps.DeveloperLaunches
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.ResolvedCard
  alias Egregoros.Repo
  alias Egregoros.Users

  setup do
    stub(Egregoros.Config.Mock, :get, fn
      :mini_apps_enabled, false -> true
      :mini_apps_domain_allowlist, [] -> []
      :mini_apps_domain_denylist, [] -> []
      key, default -> Egregoros.Config.Stub.get(key, default)
    end)

    :ok
  end

  test "binds a short-lived card to the exact opted-in user and token" do
    user = developer_user!("developer-launch-owner")
    other_user = developer_user!("developer-launch-other")

    assert {:ok, card} = DeveloperLaunches.put(user, resolved_card())
    assert card.object_id == nil
    assert card.developer_user_id == user.id

    assert %{} = DeveloperLaunches.get_active(card.id, card.resolution_token, user)

    assert DeveloperLaunches.get_active(card.id, card.resolution_token, other_user) == nil

    assert DeveloperLaunches.get_active(card.id, Ecto.UUID.generate(), user) == nil
  end

  test "a new diagnostic replaces the user's previous launch" do
    user = developer_user!("developer-launch-replace")

    assert {:ok, old_card} = DeveloperLaunches.put(user, resolved_card())

    assert {:ok, new_card} =
             DeveloperLaunches.put(
               user,
               resolved_card(%{source_url: "https://app.example/second"})
             )

    assert old_card.id != new_card.id
    assert DeveloperLaunches.get_active(old_card.id, old_card.resolution_token, user) == nil

    assert %{} =
             DeveloperLaunches.get_active(new_card.id, new_card.resolution_token, user)
  end

  test "disabling developer mode immediately invalidates an existing launch" do
    user = developer_user!("developer-launch-disabled")
    assert {:ok, card} = DeveloperLaunches.put(user, resolved_card())

    user = user |> Ecto.Changeset.change(developer_mode: false) |> Repo.update!()

    assert DeveloperLaunches.get_active(card.id, card.resolution_token, user) == nil
    refute DeveloperLaunches.active?(card)
  end

  test "rejects malformed resolved cards instead of trusting an internal struct" do
    user = developer_user!("developer-launch-invalid")

    assert {:error, :invalid_developer_launch} =
             DeveloperLaunches.put(
               user,
               resolved_card(%{launch_url: "https://attacker.example/launch"})
             )

    assert {:error, :invalid_developer_launch} =
             DeveloperLaunches.put(
               user,
               resolved_card(%{title: String.duplicate("x", 81)})
             )

    wrong_manifest = %{resolved_card().manifest | origin: "https://other.example"}

    assert {:error, :invalid_developer_launch} =
             DeveloperLaunches.put(user, resolved_card(%{manifest: wrong_manifest}))
  end

  defp developer_user!(nickname) do
    {:ok, user} = Users.create_local_user(nickname)
    {:ok, user} = Users.update_profile(user, %{"developer_mode" => true})
    user
  end

  defp resolved_card(overrides \\ %{}) do
    manifest = %Manifest{
      version: "1",
      name: "Reader",
      origin: "https://app.example",
      home_url: "https://app.example/",
      capabilities: [],
      cache_ttl_seconds: 600
    }

    struct!(
      ResolvedCard,
      Map.merge(
        %{
          source_url: "https://app.example/read",
          app_origin: "https://app.example",
          app_name: "Reader",
          title: "Reader",
          button_title: "Open",
          launch_url: "https://app.example/read",
          image_url: nil,
          manifest: manifest
        },
        overrides
      )
    )
  end
end
