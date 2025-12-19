defmodule PleromaReduxWeb.InboxControllerTest do
  use PleromaReduxWeb.ConnCase, async: true

  alias PleromaRedux.Objects
  alias PleromaRedux.Users

  test "POST /users/:nickname/inbox ingests activity", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("frank")
    {public_key, private_key} = PleromaRedux.Keys.generate_rsa_keypair()
    {:ok, _} =
      Users.create_user(%{
        nickname: "alice",
        ap_id: "https://remote.example/users/alice",
        inbox: "https://remote.example/users/alice/inbox",
        outbox: "https://remote.example/users/alice/outbox",
        public_key: public_key,
        private_key: private_key,
        local: false
      })

    note = %{
      "id" => "https://remote.example/objects/1",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello from remote"
    }

    conn =
      conn
      |> sign_request("post", "/users/frank/inbox", private_key, "https://remote.example/users/alice#main-key")
      |> post("/users/frank/inbox", note)

    assert response(conn, 202)

    assert Objects.get_by_ap_id(note["id"])
  end

  test "POST /users/:nickname/inbox rejects invalid signature", %{conn: conn} do
    {:ok, _user} = Users.create_local_user("frank")

    note = %{
      "id" => "https://remote.example/objects/2",
      "type" => "Note",
      "attributedTo" => "https://remote.example/users/alice",
      "content" => "Hello from remote"
    }

    conn = post(conn, "/users/frank/inbox", note)
    assert response(conn, 401)

    refute Objects.get_by_ap_id(note["id"])
  end

  defp sign_request(conn, method, path, private_key_pem, key_id) do
    date = Plug.Conn.get_req_header(conn, "date") |> List.first() || date_header()

    conn =
      if Plug.Conn.get_req_header(conn, "date") == [] do
        Plug.Conn.put_req_header(conn, "date", date)
      else
        conn
      end

    signature_string = [
      "(request-target): #{String.downcase(method)} " <> path,
      "date: " <> date
    ]
    |> Enum.join("\n")

    [entry] = :public_key.pem_decode(private_key_pem)
    private_key = :public_key.pem_entry_decode(entry)
    signature = :public_key.sign(signature_string, :sha256, private_key)
    signature_b64 = Base.encode64(signature)

    header =
      "Signature " <>
        "keyId=\"#{key_id}\"," <>
        "algorithm=\"rsa-sha256\"," <>
        "headers=\"(request-target) date\"," <>
        "signature=\"#{signature_b64}\""

    Plug.Conn.put_req_header(conn, "authorization", header)
  end

  defp date_header do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    weekday =
      case :calendar.day_of_the_week({year, month, day}) do
        1 -> "Mon"
        2 -> "Tue"
        3 -> "Wed"
        4 -> "Thu"
        5 -> "Fri"
        6 -> "Sat"
        7 -> "Sun"
      end

    month_name =
      case month do
        1 -> "Jan"
        2 -> "Feb"
        3 -> "Mar"
        4 -> "Apr"
        5 -> "May"
        6 -> "Jun"
        7 -> "Jul"
        8 -> "Aug"
        9 -> "Sep"
        10 -> "Oct"
        11 -> "Nov"
        12 -> "Dec"
      end

    :io_lib.format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT", [
      weekday,
      day,
      month_name,
      year,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

end
