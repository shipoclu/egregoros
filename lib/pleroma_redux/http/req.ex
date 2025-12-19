defmodule PleromaRedux.HTTP.Req do
  @behaviour PleromaRedux.HTTP

  @impl true
  def get(url, headers) do
    case Req.get(url, headers: headers) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body, headers: response.headers}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def post(url, body, headers) do
    case Req.post(url, body: body, headers: headers) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body, headers: response.headers}}
      {:error, _} = error -> error
    end
  end
end
