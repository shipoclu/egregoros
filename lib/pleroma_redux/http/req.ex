defmodule PleromaRedux.HTTP.Req do
  @behaviour PleromaRedux.HTTP

  @default_opts [redirect: false, receive_timeout: 5_000]

  @impl true
  def get(url, headers) do
    case Req.get(url, [headers: headers] ++ @default_opts) do
      {:ok, response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def post(url, body, headers) do
    case Req.post(url, [body: body, headers: headers] ++ @default_opts) do
      {:ok, response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, _} = error ->
        error
    end
  end
end
