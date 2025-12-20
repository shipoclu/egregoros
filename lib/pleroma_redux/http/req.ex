defmodule PleromaRedux.HTTP.Req do
  @behaviour PleromaRedux.HTTP

  @default_opts [redirect: false, receive_timeout: 5_000]
  @default_req_options []
  @default_max_response_bytes 1_000_000

  defp req_options do
    Application.get_env(:pleroma_redux, :req_options, @default_req_options)
  end

  defp max_response_bytes do
    Application.get_env(:pleroma_redux, :http_max_response_bytes, @default_max_response_bytes)
  end

  defp limited_into_fun(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, chunk}, {req, resp} ->
      chunk_size = IO.iodata_length(chunk)
      current = Req.Response.get_private(resp, :pleroma_redux_http_body_bytes, 0)
      new_size = current + chunk_size

      if new_size > max_bytes do
        resp =
          resp
          |> Req.Response.put_private(:pleroma_redux_http_body_bytes, new_size)
          |> Map.replace!(:body, {:error, :response_too_large})

        {:halt, {req, resp}}
      else
        resp =
          resp
          |> Req.Response.put_private(:pleroma_redux_http_body_bytes, new_size)
          |> Map.replace!(:body, resp.body <> IO.iodata_to_binary(chunk))

        {:cont, {req, resp}}
      end
    end
  end

  @impl true
  def get(url, headers) do
    opts =
      [headers: headers, into: limited_into_fun(max_response_bytes())] ++ req_options() ++
        @default_opts

    case Req.get(url, opts) do
      {:ok, response} ->
        case response.body do
          {:error, :response_too_large} ->
            {:error, :response_too_large}

          body ->
            {:ok, %{status: response.status, body: body, headers: response.headers}}
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def post(url, body, headers) do
    opts =
      [body: body, headers: headers, into: limited_into_fun(max_response_bytes())] ++
        req_options() ++ @default_opts

    case Req.post(url, opts) do
      {:ok, response} ->
        case response.body do
          {:error, :response_too_large} ->
            {:error, :response_too_large}

          response_body ->
            {:ok, %{status: response.status, body: response_body, headers: response.headers}}
        end

      {:error, _} = error ->
        error
    end
  end
end
