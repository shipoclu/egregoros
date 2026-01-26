defmodule Egregoros.PasswordTest do
  use ExUnit.Case, async: true

  alias Egregoros.Password

  test "verify/2 supports Pleroma pbkdf2 hashes" do
    password = "correct horse battery staple"
    salt = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

    hash =
      pleroma_pbkdf2_hash(password,
        digest: :sha512,
        iterations: 1000,
        salt: salt
      )

    assert Password.verify(password, hash)
    refute Password.verify("wrong password", hash)
  end

  defp pleroma_pbkdf2_hash(password, opts) when is_binary(password) and is_list(opts) do
    digest = Keyword.get(opts, :digest, :sha512)
    iterations = Keyword.fetch!(opts, :iterations)
    salt = Keyword.fetch!(opts, :salt)

    derived =
      Plug.Crypto.KeyGenerator.generate(password, salt,
        digest: digest,
        iterations: iterations,
        length: 64
      )

    "$pbkdf2-#{digest}$#{iterations}$#{pleroma_base64(salt)}$#{pleroma_base64(derived)}"
  end

  defp pleroma_base64(bin) when is_binary(bin) do
    bin
    |> Base.encode64(padding: false)
    |> String.replace("+", ".")
  end
end
