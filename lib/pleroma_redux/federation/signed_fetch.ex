defmodule PleromaRedux.Federation.SignedFetch do
  alias PleromaRedux.Federation.InternalFetchActor
  alias PleromaRedux.HTTP
  alias PleromaRedux.SafeURL
  alias PleromaRedux.Signature.HTTP, as: HTTPSignature

  @default_accept "application/activity+json, application/ld+json"
  @default_user_agent "pleroma-redux"
  @signed_headers ["(request-target)", "host", "date"]

  def get(url, opts \\ []) when is_binary(url) and is_list(opts) do
    accept = Keyword.get(opts, :accept, @default_accept)
    user_agent = Keyword.get(opts, :user_agent, @default_user_agent)

    with :ok <- SafeURL.validate_http_url(url),
         {:ok, actor} <- InternalFetchActor.get_actor(),
         {:ok, signed} <- HTTPSignature.sign_request(actor, "get", url, "", @signed_headers),
         {:ok, response} <- HTTP.get(url, headers(signed, accept, user_agent)) do
      {:ok, response}
    else
      {:error, _} = error -> error
      _ -> {:error, :signed_fetch_failed}
    end
  end

  defp headers(signed, accept, user_agent)
       when is_map(signed) and is_binary(accept) and is_binary(user_agent) do
    [
      {"accept", accept},
      {"user-agent", user_agent},
      {"host", signed.host},
      {"date", signed.date},
      {"signature", signed.signature},
      {"authorization", signed.authorization}
    ]
  end
end

