defmodule Egregoros.Workers.RefreshPollTest do
  use Egregoros.DataCase, async: true

  import Mox

  alias Egregoros.Objects
  alias Egregoros.Pipeline
  alias Egregoros.Users
  alias Egregoros.Workers.RefreshPoll
  alias EgregorosWeb.Endpoint

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  describe "maybe_enqueue/1" do
    test "enqueues refresh for open remote poll" do
      {:ok, remote_actor} =
        Users.create_user(%{
          nickname: "refresh_poll_remote",
          ap_id: "https://remote.example/users/refresh",
          inbox: "https://remote.example/users/refresh/inbox",
          outbox: "https://remote.example/users/refresh/outbox",
          public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
          local: false
        })

      question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => remote_actor.ap_id,
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "Remote poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Yes",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "No",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: false)

      assert :ok = RefreshPoll.maybe_enqueue(poll)

      assert_enqueued(
        worker: RefreshPoll,
        queue: "federation_incoming",
        args: %{"ap_id" => poll.ap_id}
      )
    end

    test "skips enqueue for closed polls" do
      {:ok, remote_actor} =
        Users.create_user(%{
          nickname: "refresh_poll_closed_remote",
          ap_id: "https://remote.example/users/refresh_closed",
          inbox: "https://remote.example/users/refresh_closed/inbox",
          outbox: "https://remote.example/users/refresh_closed/outbox",
          public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
          local: false
        })

      question = %{
        "id" => "https://remote.example/objects/" <> Ecto.UUID.generate(),
        "type" => "Question",
        "attributedTo" => remote_actor.ap_id,
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "Closed poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Yes",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "No",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2020-01-01T00:00:00Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: false)

      assert :ok = RefreshPoll.maybe_enqueue(poll)
      refute_enqueued(worker: RefreshPoll)
    end
  end

  describe "perform/1" do
    test "refreshes counts for remote poll" do
      {:ok, remote_actor} =
        Users.create_user(%{
          nickname: "refresh_poll_fetch_remote",
          ap_id: "https://remote.example/users/refresh_fetch",
          inbox: "https://remote.example/users/refresh_fetch/inbox",
          outbox: "https://remote.example/users/refresh_fetch/outbox",
          public_key: "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----\n",
          local: false
        })

      poll_id = "https://remote.example/objects/" <> Ecto.UUID.generate()

      question = %{
        "id" => poll_id,
        "type" => "Question",
        "attributedTo" => remote_actor.ap_id,
        "context" => "https://remote.example/contexts/" <> Ecto.UUID.generate(),
        "to" => [@as_public],
        "content" => "Remote poll",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "oneOf" => [
          %{
            "name" => "Yes",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "name" => "No",
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ],
        "closed" => "2030-12-31T23:59:59Z"
      }

      {:ok, poll} = Pipeline.ingest(question, local: false)

      updated_question = %{
        question
        | "oneOf" => [
            %{
              "name" => "Yes",
              "type" => "Note",
              "replies" => %{"type" => "Collection", "totalItems" => 2}
            },
            %{
              "name" => "No",
              "type" => "Note",
              "replies" => %{"type" => "Collection", "totalItems" => 1}
            }
          ]
      }

      expect(Egregoros.HTTP.Mock, :get, fn url, _headers ->
        assert url == poll_id
        {:ok, %{status: 200, body: updated_question, headers: []}}
      end)

      assert :ok = RefreshPoll.perform(%Oban.Job{args: %{"ap_id" => poll.ap_id}})

      poll = Objects.get_by_ap_id(poll.ap_id)
      yes_option = Enum.find(poll.data["oneOf"], &(&1["name"] == "Yes"))
      no_option = Enum.find(poll.data["oneOf"], &(&1["name"] == "No"))

      assert yes_option["replies"]["totalItems"] == 2
      assert no_option["replies"]["totalItems"] == 1
    end

    test "returns ok when poll is missing" do
      assert :ok =
               RefreshPoll.perform(%Oban.Job{
                 args: %{"ap_id" => Endpoint.url() <> "/objects/missing"}
               })
    end
  end
end
