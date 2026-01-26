defmodule EgregorosWeb.Components.Shared.StatusMenu do
  @moduledoc """
  Shared component for the status action menu (copy link, open link, bookmark, delete).
  """
  use EgregorosWeb, :html

  alias Egregoros.User
  alias EgregorosWeb.ProfilePaths
  alias EgregorosWeb.URL

  attr :card_id, :string, required: true
  attr :entry, :map, required: true
  attr :current_user, :any, default: nil

  def status_menu(assigns) do
    assigns =
      assigns
      |> assign(:share_url, status_share_url(assigns.entry))
      |> assign(:can_delete?, can_delete_post?(assigns.entry, assigns.current_user))
      |> assign(:bookmarked?, Map.get(assigns.entry, :bookmarked?, false))
      |> assign(:feed_id, feed_id_for_entry(assigns.entry))
      |> assign_new(:menu_id, fn -> "#{assigns.card_id}-menu" end)

    ~H"""
    <.popover
      id={@menu_id}
      data-role="status-menu"
      summary_data_role="status-menu-trigger"
      summary_aria_label="Post actions"
      panel_class="absolute right-0 top-9 z-40 w-48 overflow-hidden"
    >
      <:trigger>
        <span class="inline-flex h-8 w-8 cursor-pointer items-center justify-center text-[color:var(--text-muted)] transition hover:bg-[color:var(--bg-subtle)] hover:text-[color:var(--text-primary)] focus-visible:outline-none focus-brutal">
          <.icon name="hero-ellipsis-horizontal" class="size-5" />
        </span>
      </:trigger>

      <button
        :if={is_binary(@share_url) and @share_url != ""}
        type="button"
        data-role="copy-link"
        data-copy-text={@share_url}
        phx-click={
          JS.dispatch("egregoros:copy")
          |> JS.push("copied_link")
          |> JS.remove_attribute("open", to: "##{@menu_id}")
        }
        class="flex w-full cursor-pointer items-center gap-3 px-4 py-2.5 text-sm font-medium text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)]"
      >
        <.icon name="hero-clipboard-document" class="size-5 text-[color:var(--text-muted)]" />
        Copy link
      </button>

      <a
        :if={is_binary(@share_url) and @share_url != ""}
        data-role="open-link"
        href={@share_url}
        target="_blank"
        rel="nofollow noopener noreferrer"
        class="flex cursor-pointer items-center gap-3 px-4 py-2.5 text-sm font-medium text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)]"
      >
        <.icon
          name="hero-arrow-top-right-on-square"
          class="size-5 text-[color:var(--text-muted)]"
        /> Open link
      </a>

      <button
        :if={@current_user}
        type="button"
        data-role="bookmark"
        phx-click="toggle_bookmark"
        phx-value-id={@entry.object.id}
        phx-value-feed-id={@feed_id}
        phx-disable-with="..."
        class={[
          "flex w-full cursor-pointer items-center gap-3 px-4 py-2.5 text-sm font-medium transition hover:bg-[color:var(--bg-subtle)]",
          @bookmarked? && "text-[color:var(--text-primary)]",
          !@bookmarked? && "text-[color:var(--text-primary)]"
        ]}
      >
        <.icon
          name={if @bookmarked?, do: "hero-bookmark-solid", else: "hero-bookmark"}
          class={[
            "size-5",
            @bookmarked? && "text-[color:var(--text-primary)]",
            !@bookmarked? && "text-[color:var(--text-muted)]"
          ]}
        />
        {if @bookmarked?, do: "Unbookmark", else: "Bookmark"}
      </button>

      <%= if @can_delete? do %>
        <div class="border-t border-[color:var(--border-muted)]">
          <button
            type="button"
            data-role="delete-post"
            phx-click={JS.toggle(to: "#delete-post-confirm-#{@card_id}")}
            class="flex w-full cursor-pointer items-center gap-3 px-4 py-2.5 text-sm font-medium text-[color:var(--danger)] transition hover:bg-[color:var(--danger-subtle)]"
          >
            <.icon name="hero-trash" class="size-5" /> Delete post
          </button>

          <div
            id={"delete-post-confirm-#{@card_id}"}
            class="hidden space-y-3 px-4 pb-4 pt-2 text-sm"
          >
            <p class="text-[color:var(--text-muted)]">
              This cannot be undone.
            </p>

            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                data-role="delete-post-cancel"
                phx-click={JS.hide(to: "#delete-post-confirm-#{@card_id}")}
                class="inline-flex cursor-pointer items-center justify-center border border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--text-primary)] transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
              >
                Cancel
              </button>

              <button
                type="button"
                data-role="delete-post-confirm"
                phx-click="delete_post"
                phx-value-id={@entry.object.id}
                phx-disable-with="Deleting..."
                class="inline-flex cursor-pointer items-center justify-center border-2 border-[color:var(--danger)] bg-[color:var(--danger)] px-3 py-1.5 text-xs font-bold uppercase text-[color:var(--bg-base)] transition hover:bg-[color:var(--danger-subtle)] hover:text-[color:var(--danger)] focus-visible:outline-none focus-brutal"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </.popover>
    """
  end

  defp can_delete_post?(
         %{object: %{type: type, local: true, actor: actor_ap_id}},
         %User{ap_id: actor_ap_id}
       )
       when is_binary(actor_ap_id) and actor_ap_id != "" and type in ["Note", "Question"] do
    true
  end

  defp can_delete_post?(_entry, _user), do: false

  defp feed_id_for_entry(%{feed_id: id}) when is_binary(id), do: id
  defp feed_id_for_entry(%{object: %{id: id}}) when is_binary(id), do: id
  defp feed_id_for_entry(%{object: %{"id" => id}}) when is_binary(id), do: id
  defp feed_id_for_entry(_entry), do: nil

  defp status_share_url(entry) when is_map(entry) do
    object = Map.get(entry, :object) || %{}
    ap_id = Map.get(object, :ap_id) || Map.get(object, "ap_id")
    path = status_permalink_path(entry)

    cond do
      Map.get(object, :local) == true and is_binary(path) and path != "" ->
        URL.absolute(path)

      is_binary(ap_id) and ap_id != "" ->
        if safe_http_url?(ap_id), do: ap_id, else: nil

      true ->
        nil
    end
  end

  defp status_permalink_path(%{object: %{local: true} = object, actor: %{nickname: nickname}})
       when is_binary(nickname) and nickname != "" do
    case URL.local_object_uuid(Map.get(object, :ap_id)) do
      uuid when is_binary(uuid) and uuid != "" -> "/@#{nickname}/#{uuid}"
      _ -> nil
    end
  end

  defp status_permalink_path(%{object: %{id: id, local: false}, actor: actor})
       when is_binary(id) do
    case ProfilePaths.profile_path(actor) do
      "/@" <> _rest = profile_path -> profile_path <> "/" <> id
      _ -> nil
    end
  end

  defp status_permalink_path(_entry), do: nil

  defp safe_http_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp safe_http_url?(_url), do: false
end
