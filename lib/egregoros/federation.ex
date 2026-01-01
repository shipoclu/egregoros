defmodule Egregoros.Federation do
  alias Egregoros.Activities.Follow
  alias Egregoros.Federation.Actor
  alias Egregoros.Federation.WebFinger
  alias Egregoros.Mentions
  alias Egregoros.Pipeline
  alias Egregoros.SafeURL
  alias Egregoros.User
  alias Egregoros.Users
  alias Egregoros.Workers.FollowRemote

  def follow_remote(%User{} = local_user, handle) when is_binary(handle) do
    with {:ok, actor_url} <- WebFinger.lookup(handle),
         {:ok, remote_user} <- Actor.fetch_and_store(actor_url),
         {:ok, _follow} <- Pipeline.ingest(Follow.build(local_user, remote_user), local: true) do
      {:ok, remote_user}
    end
  end

  def follow_remote_async(%User{id: user_id} = local_user, handle)
      when is_integer(user_id) and is_binary(handle) do
    with {:ok, nickname, host} <- parse_remote_handle(handle),
         :ok <- SafeURL.validate_http_url_no_dns("https://" <> host <> "/") do
      handle = nickname <> "@" <> String.downcase(host)

      case Users.get_by_handle(handle) do
        %User{local: false} = remote_user ->
          with {:ok, _follow} <-
                 Pipeline.ingest(Follow.build(local_user, remote_user), local: true) do
            {:ok, remote_user}
          end

        _ ->
          _ = Oban.insert(FollowRemote.new(%{"user_id" => user_id, "handle" => handle}))
          {:ok, :queued}
      end
    else
      :error -> {:error, :invalid_handle}
      {:error, _} = error -> error
      _ -> {:error, :invalid_handle}
    end
  end

  def follow_remote_async(_local_user, _handle), do: {:error, :invalid_handle}

  defp parse_remote_handle(handle) when is_binary(handle) do
    case Mentions.parse(handle) do
      {:ok, nickname, host} when is_binary(host) and host != "" ->
        {:ok, nickname, host}

      _ ->
        :error
    end
  end
end
