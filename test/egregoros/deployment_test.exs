defmodule Egregoros.DeploymentTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Deployment
  alias Egregoros.Users

  test "bootstrap_admin/1 promotes an existing local user" do
    {:ok, user} = Users.create_local_user("alice")
    assert user.admin == false

    assert :ok = Deployment.bootstrap_admin("alice")

    assert Users.get(user.id).admin == true
  end

  test "bootstrap_admin/1 returns an error when the user doesn't exist" do
    assert {:error, :user_not_found} = Deployment.bootstrap_admin("missing")
  end

  test "bootstrap_admin/1 is a no-op when nickname is blank" do
    assert :ok = Deployment.bootstrap_admin("")
    assert :ok = Deployment.bootstrap_admin("   ")
  end
end
