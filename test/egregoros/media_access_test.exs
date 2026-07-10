defmodule Egregoros.MediaAccessTest do
  use Egregoros.DataCase, async: true

  alias Egregoros.Media
  alias Egregoros.Objects
  alias Egregoros.Publish.PostBuilder
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  test "binding an attachment records its post and only makes publicly addressed media public" do
    {:ok, author} = Users.create_local_user("media-binding-author")
    {:ok, recipient} = Users.create_local_user("media-binding-recipient")

    {:ok, public_media} = create_media(author, "/uploads/media/#{author.id}/public.png")
    {:ok, private_media} = create_media(author, "/uploads/media/#{author.id}/private.png")

    {:ok, public_post} =
      create_post(author, public_media, %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      })

    {:ok, private_post} =
      create_post(author, private_media, %{"to" => [recipient.ap_id], "cc" => []})

    assert :ok = Media.bind_attachments(public_post)
    assert :ok = Media.bind_attachments(private_post)

    public_state = Objects.get_by_ap_id(public_media.ap_id).internal["media"]
    private_state = Objects.get_by_ap_id(private_media.ap_id).internal["media"]

    assert public_state["public"] == true
    assert public_state["post_ap_ids"] == [public_post.ap_id]
    assert private_state["public"] == false
    assert private_state["post_ap_ids"] == [private_post.ap_id]
  end

  test "private attachment URLs use the session-bearing application origin" do
    attachment = %{
      "id" => Endpoint.url() <> "/objects/media",
      "type" => "Image",
      "url" => [
        %{
          "type" => "Link",
          "href" => "https://i.example.test/uploads/media/user/private.png"
        }
      ],
      "icon" => %{"url" => "https://i.example.test/uploads/media/user/private-thumb.jpg"}
    }

    post =
      %{}
      |> PostBuilder.put_attachments([attachment], "direct")

    [rewritten] = post["attachment"]

    assert get_in(rewritten, ["url", Access.at(0), "href"]) ==
             Endpoint.url() <> "/uploads/media/user/private.png"

    assert rewritten["icon"]["url"] ==
             Endpoint.url() <> "/uploads/media/user/private-thumb.jpg"
  end

  defp create_media(author, path) do
    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()

    Objects.create_object(%{
      ap_id: ap_id,
      type: "Image",
      actor: author.ap_id,
      local: true,
      data: %{
        "id" => ap_id,
        "type" => "Image",
        "url" => [%{"type" => "Link", "href" => Endpoint.url() <> path}]
      },
      internal: %{
        "media" => %{"paths" => [path], "public" => false, "post_ap_ids" => []}
      }
    })
  end

  defp create_post(author, media, addressing) do
    ap_id = Endpoint.url() <> "/objects/" <> Ecto.UUID.generate()

    data =
      Map.merge(
        %{
          "id" => ap_id,
          "type" => "Note",
          "actor" => author.ap_id,
          "attachment" => [media.data]
        },
        addressing
      )

    Objects.create_object(%{
      ap_id: ap_id,
      type: "Note",
      actor: author.ap_id,
      local: true,
      data: data
    })
  end
end
