defmodule Egregoros.PleromaMigration.Source.Postgres do
  @moduledoc false

  @behaviour Egregoros.PleromaMigration.Source

  alias Egregoros.PleromaMigration.PostgresClient

  @user_sql """
  SELECT
    id,
    nickname,
    ap_id,
    inbox,
    public_key,
    keys,
    local,
    is_admin,
    is_locked,
    email,
    password_hash,
    name,
    bio,
    inserted_at,
    updated_at
  FROM users
  ORDER BY id
  """

  @create_sql """
  SELECT
    a.id,
    a.data,
    a.local,
    a.inserted_at,
    a.updated_at,
    o.data
  FROM activities a
  JOIN objects o
    ON (o.data->>'id') = associated_object_id(a.data)
  WHERE a.data->>'type' = 'Create'
    AND (o.data->>'type') IN ('Note', 'Question')
  ORDER BY a.id
  """

  @announce_sql """
  SELECT
    id,
    data,
    local,
    inserted_at,
    updated_at
  FROM activities
  WHERE data->>'type' = 'Announce'
  ORDER BY id
  """

  @impl true
  def list_users(opts) when is_list(opts) do
    with_conn(opts, fn conn ->
      result = PostgresClient.query!(conn, @user_sql, [], timeout: :infinity)

      users =
        Enum.map(result.rows, fn [
                                   id,
                                   nickname,
                                   ap_id,
                                   inbox,
                                   public_key,
                                   keys,
                                   local,
                                   is_admin,
                                   is_locked,
                                   email,
                                   password_hash,
                                   name,
                                   bio,
                                   inserted_at,
                                   updated_at
                                 ] ->
          {nickname, domain} = split_nickname_domain(nickname, local, ap_id)

          %{
            id: id,
            nickname: nickname,
            domain: domain,
            ap_id: ap_id,
            inbox: derive_inbox(inbox, ap_id),
            outbox: derive_outbox(ap_id),
            public_key: derive_public_key(public_key, keys),
            private_key: keys,
            local: local,
            admin: is_admin,
            locked: is_locked,
            email: email,
            password_hash: password_hash,
            name: name,
            bio: bio,
            inserted_at: to_utc_datetime(inserted_at),
            updated_at: to_utc_datetime(updated_at)
          }
        end)

      {:ok, users}
    end)
  rescue
    e -> {:error, e}
  end

  @impl true
  def list_statuses(opts) when is_list(opts) do
    with_conn(opts, fn conn ->
      create_result = PostgresClient.query!(conn, @create_sql, [], timeout: :infinity)

      creates =
        Enum.map(create_result.rows, fn [id, data, local, inserted_at, updated_at, object] ->
          %{
            activity_id: id,
            activity: data,
            object: object,
            local: local,
            inserted_at: to_utc_datetime(inserted_at),
            updated_at: to_utc_datetime(updated_at)
          }
        end)

      announce_result = PostgresClient.query!(conn, @announce_sql, [], timeout: :infinity)

      announces =
        Enum.map(announce_result.rows, fn [id, data, local, inserted_at, updated_at] ->
          %{
            activity_id: id,
            activity: data,
            local: local,
            inserted_at: to_utc_datetime(inserted_at),
            updated_at: to_utc_datetime(updated_at)
          }
        end)

      {:ok, creates ++ announces}
    end)
  rescue
    e -> {:error, e}
  end

  defp with_conn(opts, fun) when is_list(opts) and is_function(fun, 1) do
    {:ok, conn} = PostgresClient.start_link(pg_opts(opts))

    try do
      fun.(conn)
    after
      _ = PostgresClient.stop(conn)
    end
  end

  defp pg_opts(opts) do
    connection_opts =
      Keyword.take(opts, [:hostname, :username, :password, :database, :port, :ssl])

    connection_opts =
      if connection_opts == [] do
        parse_url_opts(opts)
      else
        connection_opts
      end

    connection_opts
    |> Keyword.put_new(:timeout, 60_000)
    |> Keyword.put_new(:pool_size, 1)
  end

  defp parse_url_opts(opts) do
    url =
      Keyword.get(opts, :url) ||
        Keyword.get(opts, :database_url) ||
        System.get_env("PLEROMA_DATABASE_URL") ||
        System.get_env("PLEROMA_DB_URL") ||
        raise ArgumentError, "missing Pleroma DB connection info (set PLEROMA_DATABASE_URL)"

    uri = URI.parse(url)

    {username, password} =
      case uri.userinfo do
        nil ->
          {nil, nil}

        userinfo ->
          case String.split(userinfo, ":", parts: 2) do
            [u] -> {URI.decode(u), nil}
            [u, p] -> {URI.decode(u), URI.decode(p)}
          end
      end

    database =
      case uri.path do
        nil -> nil
        "" -> nil
        "/" -> nil
        path -> String.trim_leading(path, "/")
      end

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: username,
      password: password,
      database: database
    ]
  end

  defp split_nickname_domain(nickname, local, ap_id) when is_binary(nickname) do
    if local do
      {nickname, nil}
    else
      case String.split(nickname, "@", parts: 2) do
        [nick, domain] when domain != "" -> {nick, domain}
        _ -> {nickname, domain_from_ap_id(ap_id)}
      end
    end
  end

  defp split_nickname_domain(_nickname, local, ap_id) do
    if local do
      {"", nil}
    else
      {"", domain_from_ap_id(ap_id)}
    end
  end

  defp domain_from_ap_id(ap_id) when is_binary(ap_id) do
    case URI.parse(ap_id) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp domain_from_ap_id(_ap_id), do: nil

  defp derive_outbox(ap_id) when is_binary(ap_id), do: ap_id <> "/outbox"
  defp derive_outbox(_ap_id), do: ""

  defp derive_inbox(inbox, ap_id) when is_binary(inbox) do
    case String.trim(inbox) do
      "" -> derive_inbox(nil, ap_id)
      trimmed -> trimmed
    end
  end

  defp derive_inbox(_inbox, ap_id) when is_binary(ap_id), do: String.trim(ap_id) <> "/inbox"
  defp derive_inbox(_inbox, _ap_id), do: ""

  defp derive_public_key(public_key, keys) when is_binary(public_key) do
    case String.trim(public_key) do
      "" -> derive_public_key(nil, keys)
      trimmed -> trimmed
    end
  end

  defp derive_public_key(_public_key, keys) when is_binary(keys) and keys != "" do
    with [entry | _] <- :public_key.pem_decode(keys),
         private_key <- :public_key.pem_entry_decode(entry),
         {:ok, public_key} <- rsa_public_key_from_private(private_key) do
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      |> List.wrap()
      |> :public_key.pem_encode()
      |> IO.iodata_to_binary()
    else
      _ -> nil
    end
  end

  defp derive_public_key(_public_key, _keys), do: nil

  defp rsa_public_key_from_private(
         {:RSAPrivateKey, _version, modulus, public_exponent, _private_exponent, _prime1, _prime2,
          _exponent1, _exponent2, _coefficient, _other_prime_infos}
       ) do
    {:ok, {:RSAPublicKey, modulus, public_exponent}}
  end

  defp rsa_public_key_from_private(_private_key), do: :error

  defp to_utc_datetime(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> force_utc_datetime_usec()
  end

  defp to_utc_datetime(%DateTime{} = dt), do: force_utc_datetime_usec(dt)
  defp to_utc_datetime(nil), do: nil

  defp force_utc_datetime_usec(%DateTime{microsecond: {value, _precision}} = datetime) do
    %{datetime | microsecond: {value, 6}}
  end
end
