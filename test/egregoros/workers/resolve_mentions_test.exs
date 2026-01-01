defmodule Egregoros.Workers.ResolveMentionsTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Publish
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity
  alias Egregoros.Workers.ResolveMentions

  test "perform delivers Create to remote followers even when webfinger lookup fails" do
    {:ok, local} = Users.create_local_user("alice")

    {:ok, remote_follower} =
      Users.create_user(%{
        nickname: "lain",
        ap_id: "https://lain.com/users/lain",
        inbox: "https://lain.com/users/lain/inbox",
        outbox: "https://lain.com/users/lain/outbox",
        public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
        local: false
      })

    follow = %{
      "id" => "https://lain.com/activities/follow/1",
      "type" => "Follow",
      "actor" => remote_follower.ap_id,
      "object" => local.ap_id
    }

    assert {:ok, _} = Pipeline.ingest(follow, local: false)

    stub(Egregoros.HTTP.Mock, :get, fn _url, _headers ->
      {:ok, %{status: 404, body: %{}, headers: []}}
    end)

    assert {:ok, create} = Publish.post_note(local, "hi @toast@donotsta.re")

    refute Enum.any?(all_enqueued(worker: DeliverActivity), fn job ->
             match?(%{"activity" => %{"type" => "Create"}}, job.args)
           end)

    [job] = all_enqueued(worker: ResolveMentions)
    assert :ok = perform_job(ResolveMentions, job.args)

    create_jobs =
      all_enqueued(worker: DeliverActivity)
      |> Enum.filter(fn job ->
        match?(%{"activity" => %{"type" => "Create"}}, job.args)
      end)

    assert Enum.any?(create_jobs, &(&1.args["inbox_url"] == remote_follower.inbox))

    assert %{} = note = Objects.get_by_ap_id(create.object)
    assert note.data["source"]["content"] == "hi @toast@donotsta.re"
  end

  test "perform resolves remote mentions and schedules delivery to remote recipients" do
    {:ok, local} = Users.create_local_user("alice")

    actor_url = "https://donotsta.re/users/toast"

    stub(Egregoros.HTTP.Mock, :get, fn url, _headers ->
      cond do
        url ==
            "https://donotsta.re/.well-known/webfinger?resource=acct:toast@donotsta.re" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "subject" => "acct:toast@donotsta.re",
               "links" => [
                 %{
                   "rel" => "self",
                   "type" => "application/activity+json",
                   "href" => actor_url
                 }
               ]
             },
             headers: []
           }}

        url == actor_url ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => actor_url,
               "type" => "Person",
               "preferredUsername" => "toast",
               "inbox" => actor_url <> "/inbox",
               "outbox" => actor_url <> "/outbox",
               "publicKey" => %{"publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n"}
             },
             headers: []
           }}

        true ->
          {:ok, %{status: 404, body: %{}, headers: []}}
      end
    end)

    assert {:ok, create} = Publish.post_note(local, "hi @toast@donotsta.re")

    [job] = all_enqueued(worker: ResolveMentions)
    assert :ok = perform_job(ResolveMentions, job.args)

    assert %Egregoros.User{} = remote = Users.get_by_handle("@toast@donotsta.re")
    assert remote.ap_id == actor_url

    assert %{} = note = Objects.get_by_ap_id(create.object)
    assert remote.ap_id in List.wrap(note.data["cc"])

    assert Enum.any?(List.wrap(note.data["tag"]), fn
             %{"type" => "Mention", "href" => href} -> href == remote.ap_id
             _ -> false
           end)

    create_jobs =
      all_enqueued(worker: DeliverActivity)
      |> Enum.filter(fn job ->
        match?(%{"activity" => %{"type" => "Create"}}, job.args)
      end)

    assert Enum.any?(create_jobs, &(&1.args["inbox_url"] == remote.inbox))
  end
end

