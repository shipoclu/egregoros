defmodule EgregorosWeb.Plugs.ServeInstanceActor do
  import Plug.Conn

  alias Egregoros.Federation.InstanceActor
  alias Egregoros.Keys

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    if conn.method == "GET" and conn.request_path == "/" and
         Phoenix.Controller.get_format(conn) == "json" do
      conn
      |> put_resp_header("vary", "accept")
      |> serve_actor()
      |> halt()
    else
      conn
    end
  end

  defp serve_actor(conn) do
    case InstanceActor.get_actor() do
      {:ok, actor} ->
        payload = actor_json(actor)

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode!(payload))

      {:error, _reason} ->
        send_resp(conn, 500, "Internal Server Error")
    end
  end

  defp actor_json(actor) do
    base_url = InstanceActor.ap_id()

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => base_url,
      "type" => "Application",
      "preferredUsername" => actor.nickname,
      "name" => "Egregoros",
      "summary" => "Egregoros instance actor.",
      "inbox" => actor.inbox,
      "outbox" => actor.outbox,
      "followers" => base_url <> "/followers",
      "following" => base_url <> "/following",
      "publicKey" => %{
        "id" => base_url <> "#main-key",
        "owner" => base_url,
        "publicKeyPem" => actor.public_key
      }
    }
    |> maybe_put_assertion_method(actor)
  end

  defp maybe_put_assertion_method(actor, %{ed25519_public_key: public_key})
       when is_binary(public_key) do
    base_url = InstanceActor.ap_id()

    case Keys.ed25519_public_key_multibase(public_key) do
      multibase when is_binary(multibase) ->
        Map.put(actor, "assertionMethod", [
          %{
            "id" => base_url <> "#ed25519-key",
            "type" => "Multikey",
            "controller" => base_url,
            "publicKeyMultibase" => multibase
          }
        ])

      _ ->
        actor
    end
  end

  defp maybe_put_assertion_method(actor, _user), do: actor
end
