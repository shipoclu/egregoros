defmodule Egregoros.HTTP do
  @type header :: {String.t(), String.t()}
  @type response :: %{status: pos_integer(), body: any(), headers: [header()]}

  @callback get(String.t(), [header()]) :: {:ok, response()} | {:error, term()}
  @callback post(String.t(), iodata(), [header()]) :: {:ok, response()} | {:error, term()}

  def get(url, headers \\ []) when is_binary(url) and is_list(headers) do
    impl().get(url, headers)
  end

  def post(url, body, headers \\ []) when is_binary(url) and is_list(headers) do
    impl().post(url, body, headers)
  end

  defp impl do
    Egregoros.Config.get(__MODULE__, Egregoros.HTTP.Req)
  end
end
