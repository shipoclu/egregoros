defmodule PleromaRedux.HTTP.ReqTest do
  use ExUnit.Case, async: true

  test "enforces max response body size" do
    max = Application.get_env(:pleroma_redux, :http_max_response_bytes, 1_000_000)

    Req.Test.stub(PleromaRedux.HTTP.Req, fn conn ->
      Req.Test.text(conn, String.duplicate("a", max + 1))
    end)

    assert {:error, :response_too_large} = PleromaRedux.HTTP.Req.get("https://example.com", [])
  end

  test "allows responses within the limit" do
    max = Application.get_env(:pleroma_redux, :http_max_response_bytes, 1_000_000)

    Req.Test.stub(PleromaRedux.HTTP.Req, fn conn ->
      Req.Test.text(conn, String.duplicate("a", max))
    end)

    assert {:ok, %{status: 200, body: body}} = PleromaRedux.HTTP.Req.get("https://example.com", [])
    assert byte_size(body) == max
  end
end

