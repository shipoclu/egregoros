defmodule FederationBoxTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  @poll_interval_ms 1_000

  setup_all do
    egregoros_domain = System.get_env("FEDTEST_EGREGOROS_DOMAIN", "egregoros.test")

    egregoros_base_url =
      System.get_env("FEDTEST_EGREGOROS_BASE_URL", "http://#{egregoros_domain}")

    password = System.get_env("FEDTEST_PASSWORD", "password")

    alice_nickname = System.get_env("FEDTEST_ALICE_NICKNAME", "alice")

    bob_handle = System.get_env("FEDTEST_PLEROMA_HANDLE", "@bob@pleroma.test")
    carol_handle = System.get_env("FEDTEST_MASTODON_HANDLE", "@carol@mastodon.test")

    session = register_user!(egregoros_base_url, egregoros_domain, alice_nickname, password)
    %{client_id: client_id, client_secret: client_secret} = create_oauth_app!(egregoros_base_url)

    redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
    scopes = "read follow"

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

    {:ok,
     %{
       egregoros_base_url: egregoros_base_url,
       access_token: access_token,
       alice_actor_id_variants: alice_actor_id_variants,
       bob_handle: bob_handle,
       carol_handle: carol_handle
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

  defp create_oauth_app!(base_url) when is_binary(base_url) do
    resp =
      Req.post!(
        base_url <> "/api/v1/apps",
        redirect: false,
        form: [
          {"client_name", "fedbox"},
          {"redirect_uris", "urn:ietf:wg:oauth:2.0:oob"},
          {"scopes", "read follow"},
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

  defp exchange_auth_code!(base_url, client_id, client_secret, redirect_uri, code)
       when is_binary(base_url) and is_binary(client_id) and is_binary(client_secret) and
              is_binary(redirect_uri) and is_binary(code) do
    resp =
      Req.post!(
        base_url <> "/oauth/token",
        redirect: false,
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
    Req.post!(
      base_url <> "/api/v1/follows",
      redirect: false,
      headers: [{"authorization", "Bearer " <> access_token}],
      json: %{"uri" => handle}
    )
  end

  defp webfinger_self_href(username, domain) when is_binary(username) and is_binary(domain) do
    base_url = "http://#{domain}"

    resp =
      Req.get!(
        base_url <> "/.well-known/webfinger",
        redirect: false,
        params: [{"resource", "acct:#{username}@#{domain}"}]
      )

    body = ensure_json!(resp.body)

    with links when is_list(links) <- Map.get(body, "links"),
         %{} = link <- Enum.find(links, &(&1["rel"] == "self")),
         href when is_binary(href) and href != "" <- link["href"] do
      {:ok, href}
    else
      _ -> nil
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
    url = force_http_for_fedbox_domains(url)

    resp =
      Req.get!(
        url,
        redirect: false,
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

  defp force_http_for_fedbox_domains(url) when is_binary(url) do
    %URI{} = uri = URI.parse(url)

    if uri.host in ["egregoros.test", "pleroma.test", "mastodon.test"] and uri.scheme == "https" do
      URI.to_string(%URI{uri | scheme: "http", port: nil})
    else
      url
    end
  end

  defp get_html!(base_url, path, jar)
       when is_binary(base_url) and is_binary(path) and is_map(jar) do
    resp =
      Req.get!(
        base_url <> path,
        redirect: false,
        headers: cookie_headers(jar) ++ [{"accept", "text/html"}]
      )

    jar = update_cookie_jar(jar, resp)
    {to_string(resp.body), jar}
  end

  defp post_form!(base_url, path, jar, csrf_token, fields)
       when is_binary(base_url) and is_binary(path) and is_map(jar) and is_binary(csrf_token) and
              is_list(fields) do
    resp =
      Req.post!(
        base_url <> path,
        redirect: false,
        headers: cookie_headers(jar),
        form: [{"_csrf_token", csrf_token} | fields]
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
    case Regex.run(~r/Copy this code back into the client:.*?<div[^>]*>([^<]+)<\/div>/s, html) do
      [_, code] -> String.trim(code)
      _ -> raise("oauth code not found")
    end
  end

  defp ensure_json!(%{} = body), do: body

  defp ensure_json!(body) when is_binary(body) do
    Jason.decode!(body)
  end

  defp ensure_json!(body) do
    body
    |> to_string()
    |> Jason.decode!()
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
