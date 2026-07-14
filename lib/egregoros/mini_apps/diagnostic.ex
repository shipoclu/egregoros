defmodule Egregoros.MiniApps.Diagnostic do
  @moduledoc false

  alias Egregoros.MiniApps
  alias Egregoros.MiniApps.ActorActivation
  alias Egregoros.MiniApps.CardMetadata
  alias Egregoros.MiniApps.Fetcher
  alias Egregoros.MiniApps.ImageSanitizer
  alias Egregoros.MiniApps.Manifest
  alias Egregoros.MiniApps.Origin
  alias Egregoros.MiniApps.PageMetadata
  alias Egregoros.MiniApps.ResolvedCard

  @manifest_path "/.well-known/fediverse-miniapp.json"
  @denied_permissions ~w(
    camera microphone geolocation payment usb serial bluetooth hid midi display-capture
  )

  defmodule Check do
    @moduledoc false

    @enforce_keys [:id, :label, :status, :requirement, :detail]
    defstruct [:id, :label, :status, :requirement, :detail, :url]
  end

  defmodule Report do
    @moduledoc false

    defstruct [
      :input_url,
      :normalized_url,
      :origin,
      :manifest_url,
      :manifest,
      :resolved_card,
      checks: []
    ]

    def required_pass?(%__MODULE__{checks: checks}) do
      Enum.all?(checks, fn check ->
        check.requirement != :required or check.status == :pass
      end)
    end
  end

  def run(url, host_origin) do
    report = %Report{input_url: normalize_input(url)}

    with {:ok, host_origin} <- Origin.parse_origin(host_origin),
         {:ok, report} <- validate_input(report),
         {:ok, report, manifest_response} <- fetch_manifest(report),
         {:ok, report} <- parse_manifest(report, manifest_response),
         {:ok, report, page_response} <- fetch_linked_page(report, host_origin),
         {:ok, report} <- resolve_card(report, page_response),
         report <- probe_declared_resources(report, page_response, host_origin) do
      report
    else
      {:error, %Report{} = failed} ->
        failed

      {:error, :invalid_origin} ->
        add_check(
          report,
          :host_origin,
          "Calling Egregoros origin",
          :fail,
          :required,
          "The server's external origin is not a canonical HTTPS origin."
        )
    end
  rescue
    _error ->
      add_check(
        %Report{input_url: normalize_input(url)},
        :diagnostic_internal,
        "Diagnostic completed safely",
        :fail,
        :required,
        "The diagnostic stopped after an internal error; no remote bytes were trusted."
      )
  catch
    _kind, _reason ->
      add_check(
        %Report{input_url: normalize_input(url)},
        :diagnostic_internal,
        "Diagnostic completed safely",
        :fail,
        :required,
        "The diagnostic stopped after an internal error; no remote bytes were trusted."
      )
  end

  defp validate_input(%Report{input_url: input} = report) do
    with true <- is_binary(input) and input != "",
         {:ok, normalized_url, origin} <- Origin.normalize_url(input),
         %URI{host: host} when is_binary(host) <- URI.parse(origin),
         true <- MiniApps.domain_allowed?(host) do
      report = %{
        report
        | normalized_url: normalized_url,
          origin: origin,
          manifest_url: origin <> @manifest_path
      }

      {:ok,
       report
       |> add_check(
         :input_url,
         "Public HTTPS URL",
         :pass,
         :required,
         "The URL is canonical, bounded, fragment-free, and uses a DNS hostname.",
         normalized_url
       )
       |> add_check(
         :domain_policy,
         "Instance domain policy",
         :pass,
         :required,
         "The hostname is allowed by this instance and is not a cookie-bearing Egregoros host.",
         origin
       )}
    else
      false when is_binary(input) and input != "" ->
        {:error,
         add_check(
           report,
           :domain_policy,
           "Instance domain policy",
           :fail,
           :required,
           "The hostname is blocked by instance policy, is not public, or is an Egregoros cookie host.",
           input
         )}

      _ ->
        {:error,
         add_check(
           report,
           :input_url,
           "Public HTTPS URL",
           :fail,
           :required,
           "Enter one canonical HTTPS URL with a public DNS hostname and no fragment or credentials.",
           input
         )}
    end
  end

  defp fetch_manifest(report) do
    case Fetcher.get(report.manifest_url, :manifest) do
      {:ok, response} ->
        report =
          report
          |> add_fetch_pass(:manifest, "Manifest", report.manifest_url, response)
          |> add_non_page_header_checks(:manifest, "Manifest", report.manifest_url, response)

        {:ok, report, response}

      {:error, reason} ->
        {:error,
         add_fetch_failure(
           report,
           :manifest,
           "Manifest",
           report.manifest_url,
           reason
         )}
    end
  end

  defp parse_manifest(report, %{body: body}) do
    case Manifest.decode(body, report.manifest_url) do
      {:ok, manifest} ->
        {:ok,
         report
         |> Map.put(:manifest, manifest)
         |> add_check(
           :manifest_parse,
           "Manifest schema and exact-origin URLs",
           :pass,
           :required,
           "Version, fields, capabilities, scopes, URL origins, and declared limits are valid.",
           report.manifest_url
         )}

      {:error, reason} ->
        {:error,
         add_check(
           report,
           :manifest_parse,
           "Manifest schema and exact-origin URLs",
           :fail,
           :required,
           reason_detail(reason),
           report.manifest_url
         )}
    end
  end

  defp fetch_linked_page(report, host_origin) do
    case Fetcher.get(report.normalized_url, :page) do
      {:ok, response} ->
        report =
          report
          |> add_fetch_pass(:linked_page, "Linked page", report.normalized_url, response)
          |> add_page_header_checks(
            :linked_page,
            "Linked page",
            report.normalized_url,
            response,
            host_origin,
            report.origin
          )

        {:ok, report, response}

      {:error, reason} ->
        {:error,
         add_fetch_failure(
           report,
           :linked_page,
           "Linked page",
           report.normalized_url,
           reason
         )}
    end
  end

  defp resolve_card(report, %{body: html}) do
    case PageMetadata.extract(html) do
      {:ok, nil} ->
        resolved = generic_card(report)

        {:ok,
         report
         |> Map.put(:resolved_card, resolved)
         |> add_check(
           :page_metadata,
           "Optional rich-card metadata",
           :pass,
           :required,
           "No fediverse:miniapp meta element is present; the valid generic manifest card is used.",
           report.normalized_url
         )}

      {:ok, json} when is_binary(json) ->
        case CardMetadata.decode(json, report.normalized_url, report.origin) do
          {:ok, metadata} ->
            resolved = metadata_card(report, metadata)

            {:ok,
             report
             |> Map.put(:resolved_card, resolved)
             |> add_check(
               :page_metadata,
               "Optional rich-card metadata",
               :pass,
               :required,
               "The single metadata element is strict JSON and all card URLs use the exact app origin.",
               report.normalized_url
             )}

          {:error, reason} ->
            {:ok,
             report
             |> Map.put(:resolved_card, generic_card(report))
             |> add_check(
               :page_metadata,
               "Optional rich-card metadata",
               :fail,
               :required,
               "Metadata was present but invalid: #{reason_detail(reason)} The generic card is shown only for debugging.",
               report.normalized_url
             )}
        end

      {:error, reason} ->
        {:ok,
         report
         |> Map.put(:resolved_card, generic_card(report))
         |> add_check(
           :page_metadata,
           "Optional rich-card metadata",
           :fail,
           :required,
           "The page metadata could not be parsed: #{reason_detail(reason)} The generic card is shown only for debugging.",
           report.normalized_url
         )}
    end
  end

  defp probe_declared_resources(report, linked_response, host_origin) do
    resources = resources(report)

    Enum.reduce(resources, report, fn resource, report ->
      response =
        if resource.kind == :page and resource.url == report.normalized_url do
          {:ok, linked_response}
        else
          Fetcher.get(resource.url, resource.kind)
        end

      inspect_resource(report, resource, response, host_origin)
    end)
  end

  defp resources(report) do
    manifest = report.manifest
    card = report.resolved_card

    [
      resource(:page, manifest.home_url, "Home page", :home_page),
      resource(:page, card.launch_url, "Launch page", :launch_page),
      optional_resource(:asset, manifest.icon_url, "Manifest icon", :manifest_icon),
      optional_resource(
        :asset,
        get_in(manifest.splash || %{}, [:image_url]),
        "Splash image",
        :splash_image
      ),
      optional_resource(:asset, card.image_url, "Card image", :card_image),
      optional_resource(
        :actor,
        get_in(manifest.activity_pub || %{}, [:actor_url]),
        "ActivityPub actor",
        :activity_pub_actor
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce([], fn resource, resources ->
      if Enum.any?(resources, &(&1.kind == resource.kind and &1.url == resource.url)) do
        resources
      else
        resources ++ [resource]
      end
    end)
  end

  defp resource(kind, url, label, id), do: %{kind: kind, url: url, label: label, id: id}
  defp optional_resource(_kind, nil, _label, _id), do: nil
  defp optional_resource(kind, url, label, id), do: resource(kind, url, label, id)

  defp inspect_resource(report, resource, {:ok, response}, host_origin) do
    report =
      if resource.kind == :page and resource.url == report.normalized_url do
        report
      else
        add_fetch_pass(report, resource.id, resource.label, resource.url, response)
      end

    report =
      case resource.kind do
        :page ->
          add_page_header_checks(
            report,
            resource.id,
            resource.label,
            resource.url,
            response,
            host_origin,
            report.origin
          )

        _kind ->
          add_non_page_header_checks(
            report,
            resource.id,
            resource.label,
            resource.url,
            response
          )
      end

    validate_resource_body(report, resource, response)
  end

  defp inspect_resource(report, resource, {:error, reason}, _host_origin) do
    add_fetch_failure(report, resource.id, resource.label, resource.url, reason)
  end

  defp validate_resource_body(report, %{kind: :asset} = resource, response) do
    content_type = content_type(response.headers)

    case ImageSanitizer.sanitize(response.body, content_type || "") do
      {:ok, %{body: body, content_type: safe_type}}
      when is_binary(body) and is_binary(safe_type) ->
        add_check(
          report,
          id(resource.id, :safe_image),
          "#{resource.label} decodes as a safe raster",
          :pass,
          :required,
          "The production image sanitizer accepted and normalized the image.",
          resource.url
        )

      {:error, reason} ->
        add_check(
          report,
          id(resource.id, :safe_image),
          "#{resource.label} decodes as a safe raster",
          :fail,
          :required,
          reason_detail(reason),
          resource.url
        )

      _ ->
        add_check(
          report,
          id(resource.id, :safe_image),
          "#{resource.label} decodes as a safe raster",
          :fail,
          :required,
          "The image sanitizer returned an invalid result.",
          resource.url
        )
    end
  end

  defp validate_resource_body(report, %{kind: :actor} = resource, response) do
    case ActorActivation.validate_document(response.body, report.manifest) do
      :ok ->
        add_check(
          report,
          id(resource.id, :document),
          "ActivityPub actor document",
          :pass,
          :required,
          "Actor identity, endpoints, ownership, key ID, and RSA key material are valid and exact-origin.",
          resource.url
        )

      {:error, reason} ->
        add_check(
          report,
          id(resource.id, :document),
          "ActivityPub actor document",
          :fail,
          :required,
          reason_detail(reason),
          resource.url
        )
    end
  end

  defp validate_resource_body(report, _resource, _response), do: report

  defp add_fetch_pass(report, prefix, label, url, response) do
    add_check(
      report,
      id(prefix, :fetch),
      "#{label} HTTP response",
      :pass,
      :required,
      "GET returned 200 with #{content_type(response.headers) || "the expected MIME type"}; redirects, TLS, DNS, size, and framing were accepted by the bounded fetcher.",
      url
    )
  end

  defp add_fetch_failure(report, prefix, label, url, reason) do
    add_check(
      report,
      id(prefix, :fetch),
      "#{label} HTTP response",
      :fail,
      :required,
      reason_detail(reason),
      url
    )
  end

  defp add_non_page_header_checks(report, prefix, label, url, response) do
    report
    |> add_nosniff_check(prefix, label, url, response.headers)
    |> add_hsts_check(prefix, label, url, response.headers)
  end

  defp add_page_header_checks(
         report,
         prefix,
         label,
         url,
         response,
         host_origin,
         app_origin
       ) do
    report
    |> add_nosniff_check(prefix, label, url, response.headers)
    |> add_frame_ancestors_check(prefix, label, url, response.headers, host_origin, app_origin)
    |> add_x_frame_options_check(prefix, label, url, response.headers)
    |> add_referrer_check(prefix, label, url, response.headers)
    |> add_permissions_check(prefix, label, url, response.headers)
    |> add_hsts_check(prefix, label, url, response.headers)
  end

  defp add_nosniff_check(report, prefix, label, url, headers) do
    values = header_values(headers, "x-content-type-options")
    passed? = values == ["nosniff"]

    add_check(
      report,
      id(prefix, :nosniff),
      "#{label} X-Content-Type-Options",
      status(passed?),
      :required,
      if(passed?, do: "Exactly one nosniff policy is present.", else: header_detail(values)),
      url
    )
  end

  defp add_frame_ancestors_check(report, prefix, label, url, headers, host_origin, app_origin) do
    values = header_values(headers, "content-security-policy")
    result = frame_ancestors_result(values, host_origin, app_origin)

    add_check(
      report,
      id(prefix, :frame_ancestors),
      "#{label} CSP frame-ancestors",
      status(result == :ok),
      :required,
      case result do
        :ok -> "Every enforced framing policy permits #{host_origin}."
        :missing -> "No enforced CSP frame-ancestors directive was found."
        :blocked -> "At least one enforced CSP policy blocks #{host_origin}."
        :invalid -> "The enforced CSP contains an ambiguous frame-ancestors directive."
      end,
      url
    )
  end

  defp add_x_frame_options_check(report, prefix, label, url, headers) do
    values = header_values(headers, "x-frame-options")
    passed? = values == []

    add_check(
      report,
      id(prefix, :x_frame_options),
      "#{label} X-Frame-Options",
      status(passed?),
      :required,
      if(passed?,
        do: "No legacy X-Frame-Options header can override cross-origin framing.",
        else: "Remove X-Frame-Options; received #{Enum.join(values, ", ")}."
      ),
      url
    )
  end

  defp add_referrer_check(report, prefix, label, url, headers) do
    values = header_values(headers, "referrer-policy")
    passed? = values == ["no-referrer"]

    add_check(
      report,
      id(prefix, :referrer_policy),
      "#{label} Referrer-Policy",
      status(passed?),
      :recommended,
      if(passed?, do: "No-referrer is enforced.", else: header_detail(values)),
      url
    )
  end

  defp add_permissions_check(report, prefix, label, url, headers) do
    values = header_values(headers, "permissions-policy")
    passed? = permissions_denied?(values)

    add_check(
      report,
      id(prefix, :permissions_policy),
      "#{label} Permissions-Policy",
      status(passed?),
      :recommended,
      if(passed?,
        do: "All host-denied device capabilities are explicitly disabled.",
        else: "Deny these capabilities with =(): #{Enum.join(@denied_permissions, ", ")}."
      ),
      url
    )
  end

  defp add_hsts_check(report, prefix, label, url, headers) do
    values = header_values(headers, "strict-transport-security")
    passed? = valid_hsts?(values)

    add_check(
      report,
      id(prefix, :hsts),
      "#{label} Strict-Transport-Security",
      status(passed?),
      :recommended,
      if(passed?, do: "A positive max-age is present.", else: header_detail(values)),
      url
    )
  end

  defp frame_ancestors_result([], _host_origin, _app_origin), do: :missing

  defp frame_ancestors_result(values, host_origin, app_origin) do
    policies = Enum.flat_map(values, &String.split(&1, ",", trim: true))

    directives =
      Enum.flat_map(policies, fn policy ->
        policy
        |> String.split(";", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(String.downcase(&1) |> String.starts_with?("frame-ancestors")))
      end)

    cond do
      directives == [] ->
        :missing

      Enum.any?(directives, &(length(String.split(&1, ~r/\s+/, trim: true)) < 2)) ->
        :invalid

      Enum.all?(directives, &directive_allows?(&1, host_origin, app_origin)) ->
        :ok

      true ->
        :blocked
    end
  end

  defp directive_allows?(directive, host_origin, app_origin) do
    [_name | sources] = String.split(directive, ~r/\s+/, trim: true)

    "'none'" not in Enum.map(sources, &String.downcase/1) and
      Enum.any?(sources, &source_allows?(&1, host_origin, app_origin))
  end

  defp source_allows?(source, host_origin, app_origin) do
    source = String.downcase(source)

    cond do
      source in ["*", "https:"] -> true
      source == "'self'" -> host_origin == app_origin
      match?({:ok, ^host_origin}, Origin.parse_origin(source)) -> true
      true -> wildcard_source_allows?(source, host_origin)
    end
  end

  defp wildcard_source_allows?("https://*." <> suffix, host_origin) do
    with %URI{scheme: "https", host: host, port: host_port} <- URI.parse(host_origin),
         %URI{host: suffix_host, port: suffix_port, path: path} <-
           URI.parse("https://" <> suffix),
         true <- path in [nil, ""],
         true <- (host_port || 443) == (suffix_port || 443) do
      host != suffix_host and String.ends_with?(host, "." <> suffix_host)
    else
      _ -> false
    end
  end

  defp wildcard_source_allows?(_source, _host_origin), do: false

  defp permissions_denied?([value]) do
    directives =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.replace(&1, ~r/\s+/, ""))

    Enum.all?(@denied_permissions, &((&1 <> "=()") in directives))
  end

  defp permissions_denied?(_values), do: false

  defp valid_hsts?([value]) do
    Enum.any?(String.split(value, ";", trim: true), fn directive ->
      case directive |> String.trim() |> String.downcase() |> String.split("=", parts: 2) do
        ["max-age", seconds] ->
          case Integer.parse(String.trim(seconds)) do
            {number, ""} when number > 0 -> true
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  defp valid_hsts?(_values), do: false

  defp generic_card(report) do
    %ResolvedCard{
      source_url: report.normalized_url,
      app_origin: report.origin,
      app_name: report.manifest.name,
      title: report.manifest.name,
      button_title: "Open",
      launch_url: report.normalized_url,
      image_url: report.manifest.icon_url,
      manifest: report.manifest
    }
  end

  defp metadata_card(report, metadata) do
    %ResolvedCard{
      source_url: report.normalized_url,
      app_origin: report.origin,
      app_name: report.manifest.name,
      title: metadata.title,
      button_title: metadata.button_title,
      launch_url: metadata.launch_url,
      image_url: metadata.image_url,
      manifest: report.manifest
    }
  end

  defp content_type(headers) do
    case header_values(headers, "content-type") do
      [value] -> value |> String.split(";", parts: 2) |> hd() |> String.trim()
      _ -> nil
    end
  end

  defp header_values(headers, name) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: [String.downcase(String.trim(value))], else: []

      _ ->
        []
    end)
  end

  defp header_values(headers, name) when is_map(headers) do
    headers
    |> Enum.flat_map(fn
      {key, values} when is_binary(key) ->
        if String.downcase(key) == name do
          values
          |> List.wrap()
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.downcase(String.trim(&1)))
        else
          []
        end

      _ ->
        []
    end)
  end

  defp header_values(_headers, _name), do: []

  defp add_check(report, id, label, status, requirement, detail, url \\ nil) do
    check = %Check{
      id: to_string(id),
      label: label,
      status: status,
      requirement: requirement,
      detail: detail,
      url: url
    }

    %{report | checks: report.checks ++ [check]}
  end

  defp id(prefix, suffix), do: "#{prefix}_#{suffix}"
  defp status(true), do: :pass
  defp status(false), do: :fail

  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(_value), do: ""

  defp header_detail([]), do: "The required response header is missing."
  defp header_detail(values), do: "Received: #{Enum.join(values, ", ")}."

  defp reason_detail({:unexpected_status, status}), do: "The server returned HTTP #{status}."

  defp reason_detail(:invalid_content_type),
    do: "The response has the wrong or ambiguous MIME type."

  defp reason_detail(:unsafe_url),
    do: "The URL or one of its DNS addresses is not public and safe."

  defp reason_detail(:domain_denied), do: "The hostname is blocked by instance policy."
  defp reason_detail(:timeout), do: "The bounded request timed out."
  defp reason_detail(:response_too_large), do: "The response exceeds the resource size limit."

  defp reason_detail(:invalid_response_headers),
    do: "The response headers are malformed, ambiguous, or oversized."

  defp reason_detail(:invalid_response_body), do: "The response body is truncated or malformed."

  defp reason_detail(:encoded_response_not_allowed),
    do: "Compressed or encoded responses are not accepted by this profile."

  defp reason_detail(:redirect_origin_mismatch), do: "A redirect left the exact app origin."
  defp reason_detail(:too_many_redirects), do: "The response exceeded the redirect limit."

  defp reason_detail(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> then(&(String.capitalize(&1) <> "."))
  end

  defp reason_detail(_reason), do: "The resource failed strict conformance validation."
end
