defmodule FederationBoxTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 240_000

  @poll_interval_ms 1_000

  setup_all do
    scheme = fedtest_scheme()

    egregoros_domain = System.get_env("FEDTEST_EGREGOROS_DOMAIN", "egregoros.test")

    egregoros_base_url =
      System.get_env("FEDTEST_EGREGOROS_BASE_URL", "#{scheme}://#{egregoros_domain}")

    password = System.get_env("FEDTEST_PASSWORD", "password")

    alice_nickname = System.get_env("FEDTEST_ALICE_NICKNAME", "alice")

    bob_handle = System.get_env("FEDTEST_PLEROMA_HANDLE", "@bob@pleroma.test")
    carol_handle = System.get_env("FEDTEST_MASTODON_HANDLE", "@carol@mastodon.test")

    %{username: bob_username, domain: bob_domain} = parse_handle!(bob_handle)
    %{username: carol_username, domain: carol_domain} = parse_handle!(carol_handle)

    pleroma_base_url = "#{scheme}://#{bob_domain}"
    mastodon_base_url = "#{scheme}://#{carol_domain}"

    session = register_user!(egregoros_base_url, egregoros_domain, alice_nickname, password)

    redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
    scopes = "read write follow"

    %{client_id: client_id, client_secret: client_secret} =
      create_oauth_app!(egregoros_base_url, scopes)

    auth_code =
      authorize_oauth_app!(egregoros_base_url, session, client_id, redirect_uri, scopes)

    access_token =
      exchange_auth_code!(egregoros_base_url, client_id, client_secret, redirect_uri, auth_code)

    alice_actor_id =
      wait_until!(
        fn -> webfinger_self_href(alice_nickname, egregoros_domain) end,
        "webfinger ready #{alice_nickname}@#{egregoros_domain}"
      )

    alice_actor_id_variants = actor_id_variants(alice_actor_id)
    alice_handle = "@#{alice_nickname}@#{egregoros_domain}"

    bob_actor_id =
      wait_until!(
        fn -> webfinger_self_href(bob_username, bob_domain) end,
        "webfinger ready #{bob_handle}"
      )

    carol_actor_id =
      wait_until!(
        fn -> webfinger_self_href(carol_username, carol_domain) end,
        "webfinger ready #{carol_handle}"
      )

    bob_actor_id_variants = actor_id_variants(bob_actor_id)
    carol_actor_id_variants = actor_id_variants(carol_actor_id)

    %{client_id: bob_client_id, client_secret: bob_client_secret} =
      create_oauth_app!(pleroma_base_url, scopes)

    bob_access_token =
      password_grant_token!(
        pleroma_base_url,
        bob_client_id,
        bob_client_secret,
        [bob_username, "#{bob_username}@#{bob_domain}"],
        password,
        scopes
      )

    %{client_id: carol_client_id, client_secret: carol_client_secret} =
      create_oauth_app!(mastodon_base_url, scopes)

    carol_session =
      mastodon_sign_in!(mastodon_base_url, "#{carol_username}@#{carol_domain}", password)

    carol_auth_code =
      authorize_rails_oauth_app!(
        mastodon_base_url,
        carol_session,
        carol_client_id,
        redirect_uri,
        scopes
      )

    carol_access_token =
      exchange_auth_code!(
        mastodon_base_url,
        carol_client_id,
        carol_client_secret,
        redirect_uri,
        carol_auth_code
      )

    {:ok,
     %{
       egregoros_base_url: egregoros_base_url,
       access_token: access_token,
       alice_handle: alice_handle,
       alice_actor_id: alice_actor_id,
       alice_actor_id_variants: alice_actor_id_variants,
       bob_handle: bob_handle,
       bob_access_token: bob_access_token,
       bob_actor_id_variants: bob_actor_id_variants,
       pleroma_base_url: pleroma_base_url,
       carol_handle: carol_handle,
       carol_access_token: carol_access_token,
       carol_actor_id_variants: carol_actor_id_variants,
       mastodon_base_url: mastodon_base_url
     }}
  end

  test "outgoing follow is accepted by pleroma", ctx do
    follow_and_assert_remote_accept!(
      ctx.egregoros_base_url,
      ctx.access_token,
      ctx.bob_handle,
      ctx.alice_actor_id_variants
    )
  end

  test "outgoing follow is accepted by mastodon", ctx do
    follow_and_assert_remote_accept!(
      ctx.egregoros_base_url,
      ctx.access_token,
      ctx.carol_handle,
      ctx.alice_actor_id_variants
    )
  end

  test "receives posts from followed accounts", ctx do
    follow_and_assert_remote_accept!(
      ctx.egregoros_base_url,
      ctx.access_token,
      ctx.bob_handle,
      ctx.alice_actor_id_variants
    )

    follow_and_assert_remote_accept!(
      ctx.egregoros_base_url,
      ctx.access_token,
      ctx.carol_handle,
      ctx.alice_actor_id_variants
    )

    unique = unique_token()
    bob_text = "fedbox: hello from bob #{unique}"
    carol_text = "fedbox: hello from carol #{unique}"

    _ = create_status!(ctx.pleroma_base_url, ctx.bob_access_token, bob_text)
    _ = create_status!(ctx.mastodon_base_url, ctx.carol_access_token, carol_text)

    wait_until!(
      fn -> home_timeline_contains?(ctx.egregoros_base_url, ctx.access_token, bob_text) end,
      "egregoros received pleroma post"
    )

    wait_until!(
      fn -> home_timeline_contains?(ctx.egregoros_base_url, ctx.access_token, carol_text) end,
      "egregoros received mastodon post"
    )
  end

  test "receives likes from mastodon on our posts", ctx do
    unique = unique_token()

    follow_and_assert_local_accept!(
      ctx.mastodon_base_url,
      ctx.carol_access_token,
      ctx.alice_handle,
      ctx.alice_actor_id,
      ctx.carol_actor_id_variants
    )

    alice_text = "fedbox: like me #{unique}"
    alice_status = create_status!(ctx.egregoros_base_url, ctx.access_token, alice_text)
    alice_status_id = alice_status["id"]

    alice_uri_variants =
      alice_status
      |> status_uri()
      |> actor_id_variants()

    mastodon_status =
      wait_until!(
        fn ->
          find_status_by_uri_variant(
            ctx.mastodon_base_url,
            ctx.carol_access_token,
            alice_uri_variants
          )
        end,
        "mastodon received alice post"
      )

    favourite_status!(ctx.mastodon_base_url, ctx.carol_access_token, mastodon_status["id"])

    wait_until!(
      fn ->
        status = fetch_status!(ctx.egregoros_base_url, ctx.access_token, alice_status_id)
        favourites_count = Map.get(status, "favourites_count", 0)
        is_integer(favourites_count) and favourites_count > 0
      end,
      "egregoros received mastodon like"
    )
  end

  defp follow_and_assert_remote_accept!(base_url, access_token, handle, alice_actor_id_variants)
       when is_binary(base_url) and is_binary(access_token) and is_binary(handle) and
              is_list(alice_actor_id_variants) do
    _ = follow_remote!(base_url, access_token, handle)

    %{username: username, domain: domain} = parse_handle!(handle)

    remote_actor_id =
      wait_until!(fn -> webfinger_self_href(username, domain) end, "actor #{handle}")

    wait_until!(
      fn ->
        followers = fetch_follower_ids(remote_actor_id)
        Enum.any?(followers, &(&1 in alice_actor_id_variants))
      end,
      "follow accepted alice -> #{handle}"
    )

    :ok
  end

  defp follow_and_assert_local_accept!(
         remote_base_url,
         remote_access_token,
         local_handle,
         local_actor_id,
         remote_actor_id_variants
       )
       when is_binary(remote_base_url) and is_binary(remote_access_token) and
              is_binary(local_handle) and
              is_binary(local_actor_id) and is_list(remote_actor_id_variants) do
    _ = follow_remote!(remote_base_url, remote_access_token, local_handle)

    wait_until!(
      fn ->
        followers = fetch_follower_ids(local_actor_id)
        Enum.any?(followers, &(&1 in remote_actor_id_variants))
      end,
      "follow accepted remote -> #{local_handle}"
    )

    :ok
  end

  defp unique_token do
    System.unique_integer([:positive])
    |> Integer.to_string()
  end

  defp create_status!(base_url, access_token, text)
       when is_binary(base_url) and is_binary(access_token) and is_binary(text) do
    resp =
      req_post!(
        base_url <> "/api/v1/statuses",
        headers: [{"authorization", "Bearer " <> access_token}],
        form: [{"status", text}, {"visibility", "public"}]
      )

    ensure_json!(resp.body)
  end

  defp fetch_status!(base_url, access_token, status_id)
       when is_binary(base_url) and is_binary(access_token) and is_binary(status_id) do
    resp =
      req_get!(
        base_url <> "/api/v1/statuses/" <> status_id,
        headers: [{"authorization", "Bearer " <> access_token}]
      )

    ensure_json!(resp.body)
  end

  defp favourite_status!(base_url, access_token, status_id)
       when is_binary(base_url) and is_binary(access_token) and is_binary(status_id) do
    _resp =
      req_post!(
        base_url <> "/api/v1/statuses/" <> status_id <> "/favourite",
        headers: [{"authorization", "Bearer " <> access_token}]
      )

    :ok
  end

  defp home_timeline_contains?(base_url, access_token, needle)
       when is_binary(base_url) and is_binary(access_token) and is_binary(needle) do
    statuses = fetch_home_timeline!(base_url, access_token, limit: 40)

    Enum.any?(statuses, fn status ->
      content = Map.get(status, "content", "")
      is_binary(content) and String.contains?(content, needle)
    end)
  end

  defp find_status_by_uri_variant(base_url, access_token, uri_variants)
       when is_binary(base_url) and is_binary(access_token) and is_list(uri_variants) do
    statuses = fetch_home_timeline!(base_url, access_token, limit: 40)

    status =
      Enum.find(statuses, fn status ->
        status
        |> status_uri()
        |> case do
          uri when is_binary(uri) -> uri in uri_variants
          _ -> false
        end
      end)

    cond do
      is_map(status) ->
        {:ok, status}

      true ->
        find_status_by_uri_variant_via_search(base_url, access_token, uri_variants)
    end
  end

  defp find_status_by_uri_variant_via_search(base_url, access_token, uri_variants)
       when is_binary(base_url) and is_binary(access_token) and is_list(uri_variants) do
    find_status_by_uri_variant_via_search_endpoint(base_url, access_token, uri_variants, :v2) ||
      find_status_by_uri_variant_via_search_endpoint(base_url, access_token, uri_variants, :v1)
  end

  defp find_status_by_uri_variant_via_search_endpoint(
         base_url,
         access_token,
         uri_variants,
         version
       )
       when is_binary(base_url) and is_binary(access_token) and is_list(uri_variants) and
              version in [:v1, :v2] do
    endpoint =
      case version do
        :v2 -> "/api/v2/search"
        :v1 -> "/api/v1/search"
      end

    Enum.find_value(uri_variants, fn query ->
      params =
        case version do
          :v2 ->
            [{"q", query}, {"type", "statuses"}, {"resolve", "true"}, {"limit", 10}]

          :v1 ->
            [{"q", query}, {"resolve", "true"}, {"limit", 10}]
        end

      resp =
        req_get!(
          base_url <> endpoint,
          headers: [{"authorization", "Bearer " <> access_token}],
          params: params
        )

      cond do
        resp.status in 200..299 ->
          body = ensure_json!(resp.body)
          statuses = Map.get(body, "statuses", [])

          Enum.find_value(statuses, fn status ->
            case status_uri(status) do
              uri when is_binary(uri) ->
                if Enum.member?(uri_variants, uri) do
                  {:ok, status}
                else
                  nil
                end

              _ ->
                nil
            end
          end)

        true ->
          nil
      end
    end)
  end

  defp fetch_home_timeline!(base_url, access_token, opts)
       when is_binary(base_url) and is_binary(access_token) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 20)

    resp =
      req_get!(
        base_url <> "/api/v1/timelines/home",
        headers: [{"authorization", "Bearer " <> access_token}],
        params: [{"limit", limit}]
      )

    ensure_json!(resp.body)
  end

  defp status_uri(%{} = status) do
    Map.get(status, "uri") || Map.get(status, "url")
  end

  defp register_user!(base_url, domain, nickname, password)
       when is_binary(base_url) and is_binary(domain) and is_binary(nickname) and
              is_binary(password) do
    {html, jar} = get_html!(base_url, "/register", %{})
    csrf_token = extract_csrf_token!(html)

    {_, jar} =
      post_form!(base_url, "/register", jar, csrf_token, [
        {"registration[nickname]", nickname},
        {"registration[email]", "#{nickname}@#{domain}"},
        {"registration[password]", password},
        {"registration[return_to]", "/"}
      ])

    %{cookie_jar: jar}
  end

  defp create_oauth_app!(base_url, scopes) when is_binary(base_url) and is_binary(scopes) do
    resp =
      req_post!(
        base_url <> "/api/v1/apps",
        form: [
          {"client_name", "fedbox"},
          {"redirect_uris", "urn:ietf:wg:oauth:2.0:oob"},
          {"scopes", scopes},
          {"website", ""}
        ]
      )

    body = ensure_json!(resp.body)

    %{
      client_id: Map.fetch!(body, "client_id"),
      client_secret: Map.fetch!(body, "client_secret")
    }
  end

  defp authorize_oauth_app!(base_url, %{cookie_jar: jar}, client_id, redirect_uri, scopes)
       when is_binary(base_url) and is_binary(client_id) and is_binary(redirect_uri) and
              is_binary(scopes) do
    query =
      URI.encode_query(%{
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => scopes,
        "state" => ""
      })

    {html, jar} = get_html!(base_url, "/oauth/authorize?" <> query, jar)
    csrf_token = extract_csrf_token!(html)

    {authorized_html, _jar} =
      post_form!(base_url, "/oauth/authorize", jar, csrf_token, [
        {"oauth[client_id]", client_id},
        {"oauth[redirect_uri]", redirect_uri},
        {"oauth[response_type]", "code"},
        {"oauth[scope]", scopes},
        {"oauth[state]", ""}
      ])

    extract_oauth_code!(authorized_html)
  end

  defp authorize_rails_oauth_app!(base_url, %{cookie_jar: jar}, client_id, redirect_uri, scopes)
       when is_binary(base_url) and is_binary(client_id) and is_binary(redirect_uri) and
              is_binary(scopes) do
    query =
      URI.encode_query(%{
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => scopes,
        "state" => ""
      })

    {html, jar} = get_html!(base_url, "/oauth/authorize?" <> query, jar)
    csrf_token = extract_csrf_token!(html)

    resp =
      req_post!(
        base_url <> "/oauth/authorize",
        headers: cookie_headers(jar),
        form: [
          {"authenticity_token", csrf_token},
          {"client_id", client_id},
          {"redirect_uri", redirect_uri},
          {"code_challenge", ""},
          {"code_challenge_method", ""},
          {"response_type", "code"},
          {"scope", scopes},
          {"state", ""}
        ]
      )

    _jar = update_cookie_jar(jar, resp)

    cond do
      resp.status in 300..399 ->
        resp
        |> Req.Response.get_header("location")
        |> List.first()
        |> case do
          location when is_binary(location) and location != "" ->
            location
            |> URI.parse()
            |> Map.get(:query, "")
            |> URI.decode_query()
            |> Map.get("code")

          _ ->
            raise("oauth code not found")
        end

      resp.status in 200..299 ->
        extract_oauth_code!(to_string(resp.body))

      true ->
        raise("unexpected oauth authorize response: #{resp.status}")
    end
  end

  defp exchange_auth_code!(base_url, client_id, client_secret, redirect_uri, code)
       when is_binary(base_url) and is_binary(client_id) and is_binary(client_secret) and
              is_binary(redirect_uri) and is_binary(code) do
    resp =
      req_post!(
        base_url <> "/oauth/token",
        form: [
          {"grant_type", "authorization_code"},
          {"code", code},
          {"client_id", client_id},
          {"client_secret", client_secret},
          {"redirect_uri", redirect_uri}
        ]
      )

    body = ensure_json!(resp.body)
    Map.fetch!(body, "access_token")
  end

  defp follow_remote!(base_url, access_token, handle)
       when is_binary(base_url) and is_binary(access_token) and is_binary(handle) do
    # Mastodon v4.5+ no longer exposes POST /api/v1/follows.
    # Prefer it when available (Pleroma, Egregoros), then fall back to
    # resolving the remote account and POST /api/v1/accounts/:id/follow.
    resp =
      req_post!(
        base_url <> "/api/v1/follows",
        headers: [{"authorization", "Bearer " <> access_token}],
        form: [{"uri", handle}]
      )

    cond do
      resp.status in 200..299 ->
        :ok

      resp.status in [404, 405] ->
        follow_remote_via_lookup!(base_url, access_token, handle)

      true ->
        raise("follow failed (POST /api/v1/follows): #{resp.status}")
    end
  end

  defp follow_remote_via_lookup!(base_url, access_token, handle)
       when is_binary(base_url) and is_binary(access_token) and is_binary(handle) do
    account_id = resolve_account_id!(base_url, access_token, handle)

    resp =
      req_post!(
        base_url <> "/api/v1/accounts/" <> account_id <> "/follow",
        headers: [{"authorization", "Bearer " <> access_token}]
      )

    if resp.status in 200..299 do
      :ok
    else
      raise("follow failed (POST /api/v1/accounts/:id/follow): #{resp.status}")
    end
  end

  defp resolve_account_id!(base_url, access_token, handle)
       when is_binary(base_url) and is_binary(access_token) and is_binary(handle) do
    acct = String.trim_leading(handle, "@")

    resp =
      req_get!(
        base_url <> "/api/v1/accounts/lookup",
        headers: [{"authorization", "Bearer " <> access_token}],
        params: [{"acct", acct}]
      )

    cond do
      resp.status in 200..299 ->
        resp.body
        |> ensure_json!()
        |> Map.fetch!("id")

      true ->
        resolve_account_id_via_search!(base_url, access_token, handle)
    end
  end

  defp resolve_account_id_via_search!(base_url, access_token, handle)
       when is_binary(base_url) and is_binary(access_token) and is_binary(handle) do
    acct = String.trim_leading(handle, "@")

    resolve =
      fn accounts ->
        accounts
        |> Enum.find(fn
          %{"acct" => ^acct} -> true
          _ -> false
        end)
        |> case do
          %{"id" => id} when is_binary(id) and id != "" ->
            {:ok, id}

          _ ->
            accounts
            |> List.first()
            |> case do
              %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
              _ -> :error
            end
        end
      end

    resp =
      req_get!(
        base_url <> "/api/v2/search",
        headers: [{"authorization", "Bearer " <> access_token}],
        params: [{"q", handle}, {"type", "accounts"}, {"resolve", "true"}, {"limit", 5}]
      )

    with status when status in 200..299 <- resp.status,
         %{} = body <- ensure_json!(resp.body),
         accounts when is_list(accounts) <- Map.get(body, "accounts"),
         {:ok, account_id} <- resolve.(accounts) do
      account_id
    else
      _ ->
        resp =
          req_get!(
            base_url <> "/api/v1/accounts/search",
            headers: [{"authorization", "Bearer " <> access_token}],
            params: [{"q", handle}, {"resolve", "true"}, {"limit", 5}]
          )

        with status when status in 200..299 <- resp.status,
             accounts when is_list(accounts) <- ensure_json!(resp.body),
             {:ok, account_id} <- resolve.(accounts) do
          account_id
        else
          _ ->
            raise("failed to resolve remote account id for #{handle}")
        end
    end
  end

  defp password_grant_token!(
         base_url,
         client_id,
         client_secret,
         usernames,
         password,
         scopes
       )
       when is_binary(base_url) and is_binary(client_id) and is_binary(client_secret) and
              is_list(usernames) and is_binary(password) and is_binary(scopes) do
    usernames
    |> Enum.find_value(fn username ->
      resp =
        req_post!(
          base_url <> "/oauth/token",
          form: [
            {"grant_type", "password"},
            {"username", username},
            {"password", password},
            {"client_id", client_id},
            {"client_secret", client_secret},
            {"scope", scopes}
          ]
        )

      if resp.status in 200..299 do
        body = ensure_json!(resp.body)
        Map.fetch!(body, "access_token")
      else
        nil
      end
    end)
    |> case do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        raise("failed to get password-grant token from #{base_url}")
    end
  end

  defp mastodon_sign_in!(base_url, email, password)
       when is_binary(base_url) and is_binary(email) and is_binary(password) do
    {html, jar} = get_html!(base_url, "/auth/sign_in", %{})
    csrf_token = extract_csrf_token!(html)

    {_, jar} =
      post_rails_form!(base_url, "/auth/sign_in", jar, csrf_token, [
        {"user[email]", email},
        {"user[password]", password}
      ])

    %{cookie_jar: jar}
  end

  defp webfinger_self_href(username, domain) when is_binary(username) and is_binary(domain) do
    base_url = "#{fedtest_scheme()}://#{domain}"

    resp =
      req_get!(
        base_url <> "/.well-known/webfinger",
        headers: [{"accept", "application/jrd+json"}],
        params: [{"resource", "acct:#{username}@#{domain}"}]
      )

    cond do
      resp.status in 200..299 ->
        with {:ok, body} <- decode_json(resp.body),
             links when is_list(links) <- Map.get(body, "links"),
             %{} = link <- Enum.find(links, &(&1["rel"] == "self")),
             href when is_binary(href) and href != "" <- link["href"] do
          {:ok, href}
        else
          _ -> nil
        end

      resp.status in 300..399 ->
        case Req.Response.get_header(resp, "location") do
          [location | _] ->
            resp =
              req_get!(
                location,
                headers: [{"accept", "application/jrd+json"}]
              )

            with status when status in 200..299 <- resp.status,
                 {:ok, body} <- decode_json(resp.body),
                 links when is_list(links) <- Map.get(body, "links"),
                 %{} = link <- Enum.find(links, &(&1["rel"] == "self")),
                 href when is_binary(href) and href != "" <- link["href"] do
              {:ok, href}
            else
              _ -> nil
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp fetch_follower_ids(remote_actor_id) when is_binary(remote_actor_id) do
    remote_actor_id
    |> fetch_ap_json!()
    |> Map.get("followers")
    |> case do
      followers_url when is_binary(followers_url) and followers_url != "" ->
        followers_url
        |> fetch_collection_page_items!()
        |> Enum.flat_map(&extract_id/1)

      _ ->
        []
    end
  end

  defp fetch_collection_page_items!(collection_url) when is_binary(collection_url) do
    collection = fetch_ap_json!(collection_url)

    cond do
      is_list(collection["orderedItems"]) ->
        collection["orderedItems"]

      is_list(collection["items"]) ->
        collection["items"]

      is_map(collection["first"]) ->
        first = collection["first"]
        Map.get(first, "orderedItems") || Map.get(first, "items") || []

      is_binary(collection["first"]) ->
        fetch_collection_page_items!(collection["first"])

      true ->
        []
    end
  end

  defp fetch_ap_json!(url) when is_binary(url) do
    resp =
      req_get!(
        url,
        headers: [{"accept", "application/activity+json"}]
      )

    ensure_json!(resp.body)
  end

  defp extract_id(id) when is_binary(id), do: [id]

  defp extract_id(%{"id" => id}) when is_binary(id), do: [id]
  defp extract_id(_), do: []

  defp parse_handle!(handle) when is_binary(handle) do
    handle
    |> String.trim_leading("@")
    |> String.split("@", parts: 2)
    |> case do
      [username, domain] when username != "" and domain != "" ->
        %{username: username, domain: domain}

      _ ->
        raise("invalid handle: #{inspect(handle)}")
    end
  end

  defp actor_id_variants(actor_id) when is_binary(actor_id) do
    actor_id = String.trim(actor_id)

    https_variant =
      actor_id
      |> URI.parse()
      |> then(fn uri ->
        case uri do
          %URI{scheme: "http"} = uri -> URI.to_string(%URI{uri | scheme: "https", port: nil})
          _ -> actor_id
        end
      end)

    http_variant =
      actor_id
      |> URI.parse()
      |> then(fn uri ->
        case uri do
          %URI{scheme: "https"} = uri -> URI.to_string(%URI{uri | scheme: "http", port: nil})
          _ -> actor_id
        end
      end)

    [actor_id, https_variant, http_variant]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  defp get_html!(base_url, path, jar)
       when is_binary(base_url) and is_binary(path) and is_map(jar) do
    resp =
      req_get!(
        base_url <> path,
        headers: cookie_headers(jar) ++ [{"accept", "text/html"}]
      )

    jar = update_cookie_jar(jar, resp)
    {to_string(resp.body), jar}
  end

  defp post_form!(base_url, path, jar, csrf_token, fields)
       when is_binary(base_url) and is_binary(path) and is_map(jar) and is_binary(csrf_token) and
              is_list(fields) do
    resp =
      req_post!(
        base_url <> path,
        headers: cookie_headers(jar),
        form: [{"_csrf_token", csrf_token} | fields]
      )

    jar = update_cookie_jar(jar, resp)
    {to_string(resp.body), jar}
  end

  defp post_rails_form!(base_url, path, jar, csrf_token, fields)
       when is_binary(base_url) and is_binary(path) and is_map(jar) and is_binary(csrf_token) and
              is_list(fields) do
    resp =
      req_post!(
        base_url <> path,
        headers: cookie_headers(jar),
        form: [{"authenticity_token", csrf_token} | fields]
      )

    jar = update_cookie_jar(jar, resp)
    {to_string(resp.body), jar}
  end

  defp cookie_headers(jar) when is_map(jar) do
    case jar do
      jar when map_size(jar) == 0 ->
        []

      jar ->
        cookie =
          jar
          |> Enum.map_join("; ", fn {name, value} -> "#{name}=#{value}" end)

        [{"cookie", cookie}]
    end
  end

  defp update_cookie_jar(jar, %Req.Response{} = resp) when is_map(jar) do
    resp
    |> Req.Response.get_header("set-cookie")
    |> Enum.reduce(jar, fn set_cookie, jar ->
      set_cookie
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.split("=", parts: 2)
      |> case do
        [name, value] when name != "" -> Map.put(jar, name, value)
        _ -> jar
      end
    end)
  end

  defp extract_csrf_token!(html) when is_binary(html) do
    case Regex.run(~r/<meta\s+name=\"csrf-token\"\s+content=\"([^\"]+)\"/i, html) do
      [_, token] -> token
      _ -> raise("csrf token not found")
    end
  end

  defp extract_oauth_code!(html) when is_binary(html) do
    with [_, code] <-
           Regex.run(
             ~r/<input[^>]*class=[\"'][^\"']*oauth-code[^\"']*[\"'][^>]*value=[\"']([^\"']+)[\"']/i,
             html
           ) ||
             Regex.run(
               ~r/<input[^>]*value=[\"']([^\"']+)[\"'][^>]*class=[\"'][^\"']*oauth-code[^\"']*[\"']/i,
               html
             ) do
      String.trim(code)
    else
      _ ->
        case Regex.run(~r/Copy this code back into the client:.*?<div[^>]*>([^<]+)<\/div>/s, html) do
          [_, code] -> String.trim(code)
          _ -> raise("oauth code not found")
        end
    end
  end

  defp ensure_json!(%{} = body), do: body

  defp ensure_json!(body) when is_list(body), do: body

  defp ensure_json!(body) when is_binary(body) do
    Jason.decode!(body)
  end

  defp ensure_json!(body) do
    body
    |> to_string()
    |> Jason.decode!()
  end

  defp decode_json(%{} = body), do: {:ok, body}

  defp decode_json(body) when is_binary(body), do: Jason.decode(body)

  defp decode_json(body) do
    body
    |> to_string()
    |> Jason.decode()
  end

  defp req_connect_options do
    case System.get_env("FEDTEST_CACERTFILE", "") |> String.trim() do
      "" ->
        []

      cacertfile ->
        [
          connect_options: [
            transport_opts: [
              verify: :verify_peer,
              cacertfile: cacertfile,
              depth: 20,
              reuse_sessions: false,
              log_level: :warning,
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ]
            ]
          ]
        ]
    end
  end

  defp fedtest_scheme do
    System.get_env("FEDTEST_SCHEME", "https")
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "http" -> "http"
      "https" -> "https"
      _ -> "https"
    end
  end

  defp req_default_opts(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https"} -> req_connect_options() ++ [redirect: false]
      _ -> [redirect: false]
    end
  end

  defp req_get!(url, opts) when is_binary(url) and is_list(opts) do
    Req.get!(url, req_default_opts(url) ++ opts)
  end

  defp req_post!(url, opts) when is_binary(url) and is_list(opts) do
    Req.post!(url, req_default_opts(url) ++ opts)
  end

  defp wait_until!(check_fun, label, timeout_ms \\ 120_000)
       when is_function(check_fun, 0) and is_binary(label) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(check_fun, label, deadline)
  end

  defp do_wait_until(check_fun, label, deadline_ms)
       when is_function(check_fun, 0) and is_binary(label) and is_integer(deadline_ms) do
    case check_fun.() do
      true ->
        :ok

      {:ok, value} ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline_ms do
          raise("timeout waiting for #{label}")
        else
          Process.sleep(@poll_interval_ms)
          do_wait_until(check_fun, label, deadline_ms)
        end
    end
  end
end
