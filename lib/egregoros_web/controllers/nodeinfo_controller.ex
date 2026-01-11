defmodule EgregorosWeb.NodeinfoController do
  use EgregorosWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Egregoros.Object
  alias Egregoros.Repo
  alias Egregoros.User
  alias EgregorosWeb.Endpoint

  def nodeinfo_index(conn, _params) do
    json(conn, %{
      "links" => [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
          "href" => Endpoint.url() <> "/nodeinfo/2.0.json"
        },
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.1",
          "href" => Endpoint.url() <> "/nodeinfo/2.1.json"
        }
      ]
    })
  end

  def nodeinfo(conn, _params) do
    render_nodeinfo(conn, "2.0")
  end

  def nodeinfo_2_1(conn, _params) do
    render_nodeinfo(conn, "2.1")
  end

  defp render_nodeinfo(conn, version) when is_binary(version) do
    user_count =
      from(u in User, where: u.local == true and u.nickname != "internal.fetch")
      |> Repo.aggregate(:count, :id)

    local_posts =
      from(o in Object, where: o.type == "Note" and o.local == true)
      |> Repo.aggregate(:count, :id)

    conn
    |> put_resp_content_type(
      "application/json; profile=http://nodeinfo.diaspora.software/ns/schema/#{version}#; charset=utf-8"
    )
    |> json(%{
      "version" => version,
      "software" => %{
        "name" => "egregoros",
        "version" => app_version()
      },
      "protocols" => ["activitypub"],
      "services" => %{"inbound" => [], "outbound" => []},
      "openRegistrations" => true,
      "usage" => %{"users" => %{"total" => user_count}, "localPosts" => local_posts},
      "metadata" => %{}
    })
  end

  defp app_version do
    case Application.spec(:egregoros, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
