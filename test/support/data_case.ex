defmodule Egregoros.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Egregoros.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Egregoros.Repo

      use Oban.Testing, repo: Egregoros.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Egregoros.DataCase
      import Mox
    end
  end

  setup tags do
    Mox.set_mox_from_context(tags)
    Mox.stub_with(Egregoros.HTTP.Mock, Egregoros.HTTP.Stub)
    Mox.stub_with(Egregoros.DNS.Mock, Egregoros.DNS.Stub)
    Mox.stub_with(Egregoros.AuthZ.Mock, Egregoros.AuthZ.Stub)
    Egregoros.Config.put_impl(Egregoros.Config.Mock)
    Mox.stub_with(Egregoros.Config.Mock, Egregoros.Config.Stub)
    Mox.stub_with(Egregoros.RateLimiter.Mock, Egregoros.RateLimiter.Stub)
    Mox.stub_with(EgregorosWeb.WebSock.Mock, EgregorosWeb.WebSock.Stub)
    Mox.verify_on_exit!(tags)
    Egregoros.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(_tags) do
    # The connection owner must outlive any LiveView / client proxy processes.
    #
    # `Phoenix.LiveViewTest` starts its proxies under the ExUnit test supervisor.
    # By also starting the SQL Sandbox owner under that supervisor (and doing so
    # before starting any LiveViews), the supervisor will shut down the LiveView
    # proxies first and only then terminate the owner, preventing intermittent
    # "Postgrex.Protocol disconnected ... client exited" noise.
    parent = self()
    repo = Egregoros.Repo

    {:ok, sup} = ExUnit.fetch_test_supervisor()

    spec =
      Supervisor.child_spec(
        {Agent,
         fn ->
           :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
           :ok = Ecto.Adapters.SQL.Sandbox.allow(repo, self(), parent)
         end},
        restart: :temporary,
        id: {__MODULE__, :sandbox_owner}
      )

    {:ok, _pid} = Supervisor.start_child(sup, spec)
  end

  def activate_mini_app_actor!(origin) when is_binary(origin) do
    declaration =
      Egregoros.Repo.get_by!(Egregoros.MiniApps.Declaration, app_origin: origin)

    declaration
    |> Ecto.Changeset.change(%{
      activity_pub_actor_fingerprint: :crypto.hash(:sha256, declaration.activity_pub_actor_url),
      activity_pub_actor_key_id: declaration.activity_pub_actor_url <> "#main-key",
      activity_pub_actor_key_fingerprint:
        :crypto.hash(:sha256, declaration.activity_pub_actor_url <> "#test-key"),
      activity_pub_actor_public_key_pem: "test-only-pinned-public-key",
      activity_pub_actor_activated_at: DateTime.utc_now()
    })
    |> Egregoros.Repo.update!()
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
