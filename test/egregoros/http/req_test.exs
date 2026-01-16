defmodule Egregoros.HTTP.ReqTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "enforces max response body size" do
    max = Application.get_env(:egregoros, :http_max_response_bytes, 1_000_000)

    Req.Test.stub(Egregoros.HTTP.Req, fn conn ->
      Req.Test.text(conn, String.duplicate("a", max + 1))
    end)

    assert {:error, :response_too_large} = Egregoros.HTTP.Req.get("https://example.com", [])
  end

  test "allows responses within the limit" do
    max = Application.get_env(:egregoros, :http_max_response_bytes, 1_000_000)

    Req.Test.stub(Egregoros.HTTP.Req, fn conn ->
      Req.Test.text(conn, String.duplicate("a", max))
    end)

    assert {:ok, %{status: 200, body: body}} =
             Egregoros.HTTP.Req.get("https://example.com", [])

    assert byte_size(body) == max
  end

  test "post/3 enforces max response body size" do
    max = Application.get_env(:egregoros, :http_max_response_bytes, 1_000_000)

    Req.Test.stub(Egregoros.HTTP.Req, fn conn ->
      Req.Test.text(conn, String.duplicate("a", max + 1))
    end)

    assert {:error, :response_too_large} = Egregoros.HTTP.Req.post("https://example.com", "", [])
  end

  test "post/3 allows responses within the limit" do
    max = Application.get_env(:egregoros, :http_max_response_bytes, 1_000_000)

    Req.Test.stub(Egregoros.HTTP.Req, fn conn ->
      Req.Test.text(conn, String.duplicate("a", max))
    end)

    assert {:ok, %{status: 200, body: body}} =
             Egregoros.HTTP.Req.post("https://example.com", "", [])

    assert byte_size(body) == max
  end

  test "returns transport errors from get/2" do
    Egregoros.Config.put_impl(Egregoros.Config.Mock)

    stub(Egregoros.Config.Mock, :get, fn
      :req_options, default ->
        Keyword.merge(default, plug: {Req.Test, Egregoros.HTTP.Req}, retry: false)

      key, default ->
        Application.get_env(:egregoros, key, default)
    end)

    Req.Test.stub(Egregoros.HTTP.Req, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Egregoros.HTTP.Req.get("https://example.com", [])
  end

  test "returns transport errors from post/3" do
    Egregoros.Config.put_impl(Egregoros.Config.Mock)

    stub(Egregoros.Config.Mock, :get, fn
      :req_options, default ->
        Keyword.merge(default, plug: {Req.Test, Egregoros.HTTP.Req}, retry: false)

      key, default ->
        Application.get_env(:egregoros, key, default)
    end)

    Req.Test.stub(Egregoros.HTTP.Req, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Egregoros.HTTP.Req.post("https://example.com", "", [])
  end
end
