defmodule Egregoros.Password do
  @algorithm "pbkdf2_sha256"
  @digest :sha256
  @key_length 32
  @salt_length 16

  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_length)
    iterations = iterations()
    derived = :crypto.pbkdf2_hmac(@digest, password, salt, iterations, @key_length)

    "#{@algorithm}$#{iterations}$#{Base.encode64(salt)}$#{Base.encode64(derived)}"
  end

  def verify(password, encoded) when is_binary(password) and is_binary(encoded) do
    cond do
      String.starts_with?(encoded, "#{@algorithm}$") ->
        verify_egregoros_pbkdf2(password, encoded)

      String.starts_with?(encoded, "$pbkdf2-") ->
        verify_pleroma_pbkdf2(password, encoded)

      true ->
        false
    end
  end

  def pleroma_hash?(encoded) when is_binary(encoded) do
    String.starts_with?(encoded, "$pbkdf2-")
  end

  def pleroma_hash?(_encoded), do: false

  defp verify_egregoros_pbkdf2(password, encoded) do
    with {:ok, iterations, salt, expected} <- decode_hash(encoded),
         derived <- :crypto.pbkdf2_hmac(@digest, password, salt, iterations, byte_size(expected)) do
      Plug.Crypto.secure_compare(derived, expected)
    else
      _ -> false
    end
  end

  defp verify_pleroma_pbkdf2(password, encoded) do
    with {:ok, digest, iterations, salt, expected} <- decode_pleroma_pbkdf2_hash(encoded),
         derived <-
           Plug.Crypto.KeyGenerator.generate(password, salt,
             digest: digest,
             iterations: iterations,
             length: byte_size(expected)
           ) do
      Plug.Crypto.secure_compare(derived, expected)
    else
      _ -> false
    end
  end

  defp decode_hash(encoded) when is_binary(encoded) do
    case String.split(encoded, "$") do
      [@algorithm, iterations, salt, hash] ->
        with {iterations, ""} <- Integer.parse(iterations),
             {:ok, salt} <- Base.decode64(salt),
             {:ok, hash} <- Base.decode64(hash) do
          {:ok, iterations, salt, hash}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp decode_pleroma_pbkdf2_hash(encoded) when is_binary(encoded) do
    case String.split(encoded, "$", trim: true) do
      ["pbkdf2-" <> digest, iterations, salt, hash] ->
        with {iterations, ""} <- Integer.parse(iterations),
             digest when is_atom(digest) <- pleroma_digest(digest),
             {:ok, salt} <- pleroma_decode64(salt),
             {:ok, hash} <- pleroma_decode64(hash) do
          {:ok, digest, iterations, salt, hash}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp pleroma_digest("sha512"), do: :sha512
  defp pleroma_digest("sha384"), do: :sha384
  defp pleroma_digest("sha256"), do: :sha256
  defp pleroma_digest("sha224"), do: :sha224
  defp pleroma_digest("sha"), do: :sha
  defp pleroma_digest("sha1"), do: :sha
  defp pleroma_digest(_), do: nil

  defp pleroma_decode64(str) when is_binary(str) do
    str
    |> String.replace(".", "+")
    |> Base.decode64(padding: false)
  end

  defp iterations do
    Egregoros.Config.get(:password_iterations, 200_000)
  end
end
