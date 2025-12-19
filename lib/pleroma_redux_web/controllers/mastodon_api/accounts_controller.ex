defmodule PleromaReduxWeb.MastodonAPI.AccountsController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.Activities.Follow
  alias PleromaRedux.Activities.Undo
  alias PleromaRedux.Federation.Actor
  alias PleromaRedux.Federation.WebFinger
  alias PleromaRedux.Objects
  alias PleromaRedux.Pipeline
  alias PleromaRedux.Relationships
  alias PleromaRedux.Users
  alias PleromaReduxWeb.Endpoint
  alias PleromaReduxWeb.MastodonAPI.AccountRenderer
  alias PleromaReduxWeb.MastodonAPI.RelationshipRenderer
  alias PleromaReduxWeb.MastodonAPI.StatusRenderer

  def verify_credentials(conn, _params) do
    json(conn, AccountRenderer.render_account(conn.assigns.current_user))
  end

  def show(conn, %{"id" => id}) do
    case Users.get(id) do
      nil -> send_resp(conn, 404, "Not Found")
      user -> json(conn, AccountRenderer.render_account(user))
    end
  end

  def lookup(conn, %{"acct" => acct}) do
    acct =
      acct
      |> to_string()
      |> String.trim()
      |> String.trim_leading("@")

    if acct == "" do
      send_resp(conn, 422, "Unprocessable Entity")
    else
      case parse_acct(acct) do
        {:local, nickname} ->
          lookup_local(conn, nickname)

        {:remote, handle} ->
          lookup_remote(conn, handle)
      end
    end
  end

  def lookup(conn, _params) do
    send_resp(conn, 422, "Unprocessable Entity")
  end

  def statuses(conn, %{"id" => id}) do
    case Users.get(id) do
      nil ->
        send_resp(conn, 404, "Not Found")

      user ->
        objects = Objects.list_notes_by_actor(user.ap_id)
        json(conn, StatusRenderer.render_statuses(objects))
    end
  end

  def relationships(conn, params) do
    ids = Map.get(params, "id", [])

    relationships =
      ids
      |> List.wrap()
      |> Enum.map(&Users.get/1)
      |> Enum.filter(&is_map/1)
      |> Enum.map(&RelationshipRenderer.render_relationship(conn.assigns.current_user, &1))

    json(conn, relationships)
  end

  def follow(conn, %{"id" => id}) do
    with %{} = target <- Users.get(id),
         {:ok, _follow} <-
           Pipeline.ingest(Follow.build(conn.assigns.current_user, target),
             local: true
           ) do
      json(conn, RelationshipRenderer.render_relationship(conn.assigns.current_user, target))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  def unfollow(conn, %{"id" => id}) do
    with %{} = target <- Users.get(id),
         %{} =
           relationship <-
           Relationships.get_by_type_actor_object(
             "Follow",
             conn.assigns.current_user.ap_id,
             target.ap_id
           ),
         {:ok, _undo} <-
           Pipeline.ingest(Undo.build(conn.assigns.current_user, relationship.activity_ap_id),
             local: true
           ) do
      json(conn, RelationshipRenderer.render_relationship(conn.assigns.current_user, target))
    else
      nil -> send_resp(conn, 404, "Not Found")
      {:error, _} -> send_resp(conn, 422, "Unprocessable Entity")
    end
  end

  defp parse_acct(acct) when is_binary(acct) do
    case String.split(acct, "@", parts: 2) do
      [nickname] when nickname != "" ->
        {:local, nickname}

      [nickname, domain] when nickname != "" and domain != "" ->
        if domain == local_domain() do
          {:local, nickname}
        else
          {:remote, nickname <> "@" <> domain}
        end

      _ ->
        {:local, acct}
    end
  end

  defp lookup_local(conn, nickname) do
    case Users.get_by_nickname(nickname) do
      nil -> send_resp(conn, 404, "Not Found")
      user -> json(conn, AccountRenderer.render_account(user))
    end
  end

  defp lookup_remote(conn, handle) do
    with {:ok, actor_url} <- WebFinger.lookup(handle),
         {:ok, user} <- Actor.fetch_and_store(actor_url) do
      json(conn, AccountRenderer.render_account(user))
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp local_domain do
    Endpoint.url()
    |> URI.parse()
    |> Map.get(:host)
  end
end
