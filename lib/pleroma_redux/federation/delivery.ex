defmodule PleromaRedux.Federation.Delivery do
  alias PleromaRedux.HTTP
  alias PleromaRedux.Signature.HTTP, as: HTTPSignature
  alias PleromaRedux.User

  def deliver(%User{} = user, inbox_url, activity) when is_binary(inbox_url) and is_map(activity) do
    body = Jason.encode!(activity)

    with {:ok, signed} <- HTTPSignature.sign_request(user, "post", inbox_url, body),
         {:ok, %{status: status} = response} <- HTTP.post(inbox_url, body, headers(signed)),
         true <- status in 200..299 do
      {:ok, response}
    else
      false -> {:error, :http_error}
      {:ok, %{status: status} = response} -> {:error, {:http_error, status, response}}
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

