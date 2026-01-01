defmodule Egregoros.CBORTest do
  use ExUnit.Case, async: true

  alias Egregoros.CBOR

  test "round-trips primitive terms" do
    for term <- [nil, true, false, 0, 1, 23, 24, 255, -1, -10, -1000] do
      assert {:ok, decoded} =
               term
               |> CBOR.encode()
               |> CBOR.decode()

      assert decoded == term
    end
  end

  test "round-trips strings, bytes, arrays, and maps" do
    term = %{
      "hello" => "world",
      "bytes" => <<0, 255, 1, 2>>,
      "list" => [1, "two", false, nil, %{"nested" => "ok"}]
    }

    assert {:ok, decoded} =
             term
             |> CBOR.encode()
             |> CBOR.decode()

    assert decoded == term
  end

  test "encodes printable utf8 binaries as text and non-printable binaries as bytes" do
    assert {:ok, "hello"} = "hello" |> CBOR.encode() |> CBOR.decode()
    assert {:ok, <<0, 255>>} = <<0, 255>> |> CBOR.encode() |> CBOR.decode()
  end

  test "decode rejects non-binary input" do
    assert {:error, :invalid_cbor} = CBOR.decode(:not_binary)
  end

  test "decode returns invalid_cbor when extra bytes remain" do
    assert {:error, :invalid_cbor} = CBOR.decode(CBOR.encode(1) <> <<0>>)
  end

  test "decode surfaces truncation and invalid encodings" do
    assert {:error, :truncated} = CBOR.decode(<<>>)

    # major 0, additional info 24 requires an extra byte.
    assert {:error, :truncated} = CBOR.decode(<<0x18>>)

    # major 0 with invalid additional info.
    assert {:error, :invalid_cbor} = CBOR.decode(<<0x1C>>)
  end

  test "decode rejects unsupported values" do
    # major 7, additional info 31 is reserved for 'break' which we don't implement.
    assert {:error, :unsupported} = CBOR.decode(<<0xFF>>)
  end

  test "decode_next returns the term and the remaining bytes" do
    encoded = CBOR.encode(1) <> CBOR.encode(2)

    assert {:ok, 1, rest} = CBOR.decode_next(encoded)
    assert {:ok, 2, <<>>} = CBOR.decode_next(rest)
  end

  test "decode_next returns an error for invalid input" do
    assert {:error, :invalid_cbor} = CBOR.decode_next(123)
  end

  test "bytes with insufficient payload are truncated" do
    # major 2 (bytes), length 2, but only 1 byte follows.
    assert {:error, :truncated} = CBOR.decode(<<0x42, 0x00>>)
  end

  test "encode raises for unsupported terms" do
    assert_raise ArgumentError, fn ->
      CBOR.encode({:tuple, :unsupported})
    end
  end
end
