defmodule Egregoros.Federation.Delivery do
  alias Egregoros.HTTP
  alias Egregoros.SafeURL
  alias Egregoros.Signature.HTTP, as: HTTPSignature
  alias Egregoros.User
  alias Egregoros.Workers.DeliverActivity

  @activitystreams_context "https://www.w3.org/ns/activitystreams"

  def deliver(%User{} = user, inbox_url, activity)
      when is_binary(inbox_url) and is_map(activity) do
    with :ok <- SafeURL.validate_http_url_federation(inbox_url) do
      Oban.insert(
        DeliverActivity.new(%{
          "user_id" => user.id,
          "inbox_url" => inbox_url,
          "activity" => activity
        })
      )
    end
  end

  def deliver_now(%User{} = user, inbox_url, activity)
      when is_binary(inbox_url) and is_map(activity) do
    activity = Map.put_new(activity, "@context", @activitystreams_context)
    body = Jason.encode!(activity)

    with :ok <- SafeURL.validate_http_url_federation(inbox_url),
         {:ok, signed} <- HTTPSignature.sign_request(user, "post", inbox_url, body),
         {:ok, %{status: status} = response} <- HTTP.post(inbox_url, body, headers(signed)) do
      if status in 200..299 do
        {:ok, response}
      else
        {:error, {:http_error, status, response}}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp headers(signed) do
    [
      {"content-type", "application/activity+json"},
      {"accept", "application/activity+json"},
      {"host", signed.host},
      {"date", signed.date},
      {"digest", signed.digest},
      {"content-length", signed.content_length},
      {"signature", signed.signature}
    ]
  end
end
