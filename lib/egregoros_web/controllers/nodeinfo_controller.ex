defmodule EgregorosWeb.NodeinfoController do
  use EgregorosWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Egregoros.InstanceSettings
  alias Egregoros.Object
  alias Egregoros.Repo
  alias Egregoros.User
  alias Egregoros.Federation.InstanceActor
  alias EgregorosWeb.Endpoint

  @default_upload_limit 40_000_000
  @default_image_upload_limit 10_000_000

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
    system_nicknames = ["internal.fetch", InstanceActor.nickname()]

    user_count =
      from(u in User, where: u.local == true and u.nickname not in ^system_nicknames)
      |> Repo.aggregate(:count, :id)

    staff_accounts =
      from(u in User,
        where:
          u.local == true and u.nickname not in ^system_nicknames and u.admin == true and
            not is_nil(u.ap_id),
        select: u.ap_id
      )
      |> Repo.all()

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
      "openRegistrations" => InstanceSettings.registrations_open?(),
      "usage" => %{"users" => %{"total" => user_count}, "localPosts" => local_posts},
      "metadata" => %{
        "nodeName" => "Egregoros",
        "nodeDescription" => "A reduced federation core with an opinionated UI.",
        "private" => false,
        "suggestions" => %{"enabled" => false},
        "staffAccounts" => staff_accounts,
        "federation" => %{
          "enabled" => true,
          "mrf_policies" => []
        },
        "pollLimits" => %{
          "max_options" => 4,
          "max_option_chars" => 50,
          "min_expiration" => 300,
          "max_expiration" => 2_592_000
        },
        "postFormats" => ["text/plain"],
        "uploadLimits" => %{
          "general" => @default_upload_limit,
          "avatar" => @default_image_upload_limit,
          "banner" => @default_image_upload_limit,
          "background" => @default_image_upload_limit
        },
        "fieldsLimits" => %{
          "maxFields" => 4,
          "maxRemoteFields" => 4,
          "nameLength" => 255,
          "valueLength" => 255
        },
        "accountActivationRequired" => false,
        "invitesEnabled" => false,
        "mailerEnabled" => false,
        "features" => [],
        "restrictedNicknames" => [],
        "skipThreadContainment" => false
      }
    })
  end

  defp app_version do
    case Application.spec(:egregoros, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
