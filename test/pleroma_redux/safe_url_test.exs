defmodule PleromaRedux.SafeURLTest do
  use ExUnit.Case, async: true

  alias PleromaRedux.SafeURL

  test "allows https urls" do
    assert :ok == SafeURL.validate_http_url("https://remote.example/users/alice")
  end

  test "rejects non-http schemes" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("file:///etc/passwd")
  end

  test "rejects localhost" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://localhost/users/alice")
  end

  test "rejects loopback ip literals" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://127.0.0.1/users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://[::1]/users/alice")
  end

  test "rejects private ip literals" do
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://10.0.0.1/users/alice")
    assert {:error, :unsafe_url} == SafeURL.validate_http_url("http://192.168.0.1/users/alice")
  end
end

