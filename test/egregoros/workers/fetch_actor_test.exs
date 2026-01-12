defmodule Egregoros.Workers.FetchActorTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Keys
  alias Egregoros.Users
  alias Egregoros.Workers.FetchActor

  test "fetches and stores missing actors" do
    ap_id = "https://remote.example/users/bob"
    {public_key, _private_key} = Keys.generate_rsa_keypair()

    expect(Egregoros.HTTP.Mock, :get, fn url, headers ->
      assert url == ap_id
      assert {"accept", "application/activity+json, application/ld+json"} in headers
      assert {"user-agent", "egregoros"} in headers

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => ap_id,
           "type" => "Person",
           "preferredUsername" => "bob",
           "inbox" => ap_id <> "/inbox",
           "outbox" => ap_id <> "/outbox",
           "publicKey" => %{
             "id" => ap_id <> "#main-key",
             "owner" => ap_id,
             "publicKeyPem" => public_key
           }
         },
         headers: []
       }}
    end)

    assert :ok = FetchActor.perform(%Oban.Job{args: %{"ap_id" => ap_id}})
    assert Users.get_by_ap_id(ap_id)
  end

  test "discards invalid args" do
    assert {:discard, :invalid_args} = FetchActor.perform(%Oban.Job{args: %{}})
    assert {:discard, :invalid_args} = FetchActor.perform(%Oban.Job{args: %{"ap_id" => 1}})
  end

  test "does not refetch actors that already exist" do
    ap_id = "https://remote.example/users/bob"

    {:ok, _remote} =
      Users.create_user(%{
        nickname: "bob",
        domain: "remote.example",
        ap_id: ap_id,
        inbox: ap_id <> "/inbox",
        outbox: ap_id <> "/outbox",
        public_key: "PUB",
        private_key: nil,
        local: false
      })

    stub(Egregoros.HTTP.Mock, :get, fn _url, _headers ->
      flunk("unexpected HTTP GET during FetchActor.perform/1")
    end)

    assert :ok = FetchActor.perform(%Oban.Job{args: %{"ap_id" => ap_id}})
  end

  test "returns an error when the actor url is unsafe" do
    assert {:error, :unsafe_url} = FetchActor.perform(%Oban.Job{args: %{"ap_id" => "not-a-url"}})
  end
end
