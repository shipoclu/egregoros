defmodule Egregoros.Workers.FollowRemoteTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Users
  alias Egregoros.Workers.DeliverActivity
  alias Egregoros.Workers.FollowRemote

  test "perform/1 follows a remote user by discovering their actor via WebFinger" do
    {:ok, local} = Users.create_local_user("alice")

    webfinger_url =
      "https://remote.example/.well-known/webfinger?resource=acct:bob@remote.example"

    actor_url = "https://remote.example/users/bob"

    actor = %{
      "id" => actor_url,
      "type" => "Person",
      "preferredUsername" => "bob",
      "inbox" => "https://remote.example/users/bob/inbox",
      "outbox" => "https://remote.example/users/bob/outbox",
      "publicKey" => %{
        "id" => actor_url <> "#main-key",
        "owner" => actor_url,
        "publicKeyPem" => "remote-key"
      }
    }

    jrd = %{
      "subject" => "acct:bob@remote.example",
      "links" => [
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => actor_url
        }
      ]
    }

    expect(Egregoros.HTTP.Mock, :get, 2, fn
      ^webfinger_url, _headers ->
        {:ok, %{status: 200, body: jrd, headers: []}}

      ^actor_url, _headers ->
        {:ok, %{status: 200, body: actor, headers: []}}
    end)

    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    assert :ok =
             perform_job(FollowRemote, %{
               "user_id" => local.id,
               "handle" => "bob@remote.example"
             })

    remote = Users.get_by_handle("bob@remote.example")
    assert %Egregoros.User{local: false} = remote

    assert Objects.get_by_type_actor_object("Follow", local.ap_id, remote.ap_id)

    follow_jobs =
      all_enqueued(worker: DeliverActivity)
      |> Enum.filter(fn job ->
        match?(%{"activity" => %{"type" => "Follow"}}, job.args)
      end)

    assert Enum.any?(follow_jobs, &(&1.args["inbox_url"] == remote.inbox))
  end

  test "perform/1 discards jobs for unknown local users" do
    assert {:discard, :unknown_user} =
             perform_job(FollowRemote, %{
               "user_id" => -1,
               "handle" => "bob@remote.example"
             })
  end

  test "perform/1 discards jobs with invalid args" do
    assert {:discard, :invalid_args} = perform_job(FollowRemote, %{"user_id" => 1})
  end

  test "perform/1 discards jobs with invalid handles without doing HTTP" do
    {:ok, local} = Users.create_local_user("alice")

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers -> :ok end)
    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    assert {:discard, :invalid_handle} =
             perform_job(FollowRemote, %{
               "user_id" => local.id,
               "handle" => "not-a-handle"
             })
  end

  test "perform/1 discards jobs with unsafe handles without doing HTTP" do
    {:ok, local} = Users.create_local_user("alice")

    expect(Egregoros.HTTP.Mock, :get, 0, fn _url, _headers -> :ok end)
    expect(Egregoros.HTTP.Mock, :post, 0, fn _url, _body, _headers -> :ok end)

    assert {:discard, :unsafe_url} =
             perform_job(FollowRemote, %{
               "user_id" => local.id,
               "handle" => "bob@127.0.0.1"
             })
  end
end
