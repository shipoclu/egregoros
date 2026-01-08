defmodule EgregorosWeb.MessagesLive do
  use EgregorosWeb, :live_view

  alias Egregoros.DirectMessages
  alias Egregoros.Media
  alias Egregoros.MediaStorage
  alias Egregoros.Notifications
  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Timeline
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.Live.Uploads, as: LiveUploads
  alias EgregorosWeb.MentionAutocomplete
  alias EgregorosWeb.Param
  alias EgregorosWeb.ViewModels.Status, as: StatusVM

  @page_size 20

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case Map.get(session, "user_id") do
        nil -> nil
        id -> Users.get(id)
      end

    if connected?(socket) and match?(%User{}, current_user) do
      Phoenix.PubSub.subscribe(Egregoros.PubSub, Timeline.user_topic(current_user.ap_id))
    end

    messages = DirectMessages.list_for_user(current_user, limit: @page_size)

    {:ok,
     socket
     |> assign(
       current_user: current_user,
       notifications_count: notifications_count(current_user),
       dm_form:
         Phoenix.Component.to_form(%{"recipient" => "", "content" => "", "e2ee_dm" => ""},
           as: :dm
         ),
       mention_suggestions: %{},
       reply_modal_open?: false,
       reply_to_ap_id: nil,
       reply_to_handle: nil,
       reply_form: Phoenix.Component.to_form(default_reply_params(), as: :reply),
       reply_media_alt: %{},
       reply_options_open?: false,
       reply_cw_open?: false,
       dm_cursor: cursor(messages),
       dm_end?: length(messages) < @page_size
     )
     |> allow_upload(:reply_media,
       accept: ~w(
          .png
          .jpg
          .jpeg
          .webp
          .gif
          .heic
          .heif
          .mp4
          .webm
          .mov
          .m4a
          .mp3
          .ogg
          .opus
          .wav
          .aac
        ),
       max_entries: 4,
       max_file_size: 10_000_000,
       auto_upload: true
     )
     |> stream(:messages, StatusVM.decorate_many(messages, current_user),
       dom_id: &message_dom_id/1
     )}
  end

  @impl true
  def handle_info({:post_created, post}, socket) do
    case socket.assigns.current_user do
      %User{} = user ->
        if include_dm?(post, user) do
          {:noreply, stream_insert(socket, :messages, StatusVM.decorate(post, user), at: 0)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("mention_search", %{"q" => q, "scope" => scope}, socket) do
    q = q |> to_string() |> String.trim() |> String.trim_leading("@")
    scope = scope |> to_string() |> String.trim()

    suggestions =
      if q == "" or scope == "" do
        []
      else
        MentionAutocomplete.suggestions(q, limit: 8, current_user: socket.assigns.current_user)
      end

    mention_suggestions =
      socket.assigns.mention_suggestions
      |> Map.put(scope, suggestions)

    {:noreply, assign(socket, mention_suggestions: mention_suggestions)}
  end

  def handle_event("mention_clear", %{"scope" => scope}, socket) do
    scope = scope |> to_string() |> String.trim()

    mention_suggestions =
      socket.assigns.mention_suggestions
      |> Map.delete(scope)

    {:noreply, assign(socket, mention_suggestions: mention_suggestions)}
  end

  def handle_event(
        "open_reply_modal",
        %{"in_reply_to" => in_reply_to, "actor_handle" => actor_handle},
        socket
      ) do
    if socket.assigns.current_user do
      in_reply_to = in_reply_to |> to_string() |> String.trim()
      actor_handle = actor_handle |> to_string() |> String.trim()

      if in_reply_to == "" do
        {:noreply, socket}
      else
        parent = Objects.get_by_ap_id(in_reply_to)

        visibility =
          if match?(%{}, parent) and DirectMessages.direct?(parent) do
            "direct"
          else
            "public"
          end

        reply_params =
          default_reply_params()
          |> Map.put("in_reply_to", in_reply_to)
          |> Map.put("visibility", visibility)

        socket =
          socket
          |> LiveUploads.cancel_all(:reply_media)
          |> assign(
            reply_modal_open?: true,
            reply_to_ap_id: in_reply_to,
            reply_to_handle: actor_handle,
            reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
            reply_media_alt: %{},
            reply_options_open?: false,
            reply_cw_open?: false
          )

        {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Register to reply.")}
    end
  end

  def handle_event("close_reply_modal", _params, socket) do
    socket =
      socket
      |> LiveUploads.cancel_all(:reply_media)
      |> assign(
        reply_modal_open?: false,
        reply_to_ap_id: nil,
        reply_to_handle: nil,
        reply_form: Phoenix.Component.to_form(default_reply_params(), as: :reply),
        reply_media_alt: %{},
        reply_options_open?: false,
        reply_cw_open?: false
      )

    {:noreply, socket}
  end

  def handle_event("toggle_reply_cw", _params, socket) do
    {:noreply, assign(socket, reply_cw_open?: !socket.assigns.reply_cw_open?)}
  end

  def handle_event("reply_change", %{"reply" => %{} = reply_params}, socket) do
    reply_params = Map.merge(default_reply_params(), reply_params)
    media_alt = Map.get(reply_params, "media_alt", %{})

    reply_options_open? = Param.truthy?(Map.get(reply_params, "ui_options_open"))

    reply_cw_open? =
      socket.assigns.reply_cw_open? ||
        reply_params |> Map.get("spoiler_text", "") |> to_string() |> String.trim() != ""

    {:noreply,
     assign(socket,
       reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
       reply_media_alt: media_alt,
       reply_options_open?: reply_options_open?,
       reply_cw_open?: reply_cw_open?
     )}
  end

  def handle_event("cancel_reply_media", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:reply_media, ref)
     |> assign(:reply_media_alt, Map.delete(socket.assigns.reply_media_alt, ref))}
  end

  def handle_event("create_reply", %{"reply" => %{} = reply_params}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Register to reply.")}

      user ->
        in_reply_to =
          case socket.assigns.reply_to_ap_id do
            ap_id when is_binary(ap_id) -> String.trim(ap_id)
            _ -> reply_params |> Map.get("in_reply_to", "") |> to_string() |> String.trim()
          end

        if in_reply_to != "" do
          reply_params = Map.merge(default_reply_params(), reply_params)
          content = reply_params |> Map.get("content", "") |> to_string()
          media_alt = Map.get(reply_params, "media_alt", %{})
          visibility = Map.get(reply_params, "visibility", "direct")
          spoiler_text = Map.get(reply_params, "spoiler_text")
          sensitive = Map.get(reply_params, "sensitive")
          language = Map.get(reply_params, "language")

          reply_options_open? = Param.truthy?(Map.get(reply_params, "ui_options_open"))

          reply_cw_open? =
            socket.assigns.reply_cw_open? ||
              reply_params |> Map.get("spoiler_text", "") |> to_string() |> String.trim() != ""

          upload = socket.assigns.uploads.reply_media

          cond do
            Enum.any?(upload.entries, &(!&1.done?)) ->
              {:noreply,
               socket
               |> put_flash(:error, "Wait for attachments to finish uploading.")
               |> assign(
                 reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
                 reply_media_alt: media_alt,
                 reply_options_open?: reply_options_open?,
                 reply_cw_open?: reply_cw_open?
               )}

            upload.errors != [] or Enum.any?(upload.entries, &(!&1.valid?)) ->
              {:noreply,
               socket
               |> put_flash(:error, "Remove invalid attachments before posting.")
               |> assign(
                 reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
                 reply_media_alt: media_alt,
                 reply_options_open?: reply_options_open?,
                 reply_cw_open?: reply_cw_open?
               )}

            true ->
              attachments =
                consume_uploaded_entries(socket, :reply_media, fn %{path: path}, entry ->
                  upload = %Plug.Upload{
                    path: path,
                    filename: entry.client_name,
                    content_type: entry.client_type
                  }

                  description =
                    media_alt |> Map.get(entry.ref, "") |> to_string() |> String.trim()

                  with {:ok, url_path} <- MediaStorage.store_media(user, upload),
                       {:ok, object} <-
                         Media.create_media_object(user, upload, url_path,
                           description: description
                         ) do
                    {:ok, object.data}
                  else
                    {:error, reason} -> {:ok, {:error, reason}}
                  end
                end)

              case Enum.find(attachments, &match?({:error, _}, &1)) do
                {:error, _reason} ->
                  {:noreply,
                   socket
                   |> put_flash(:error, "Could not upload attachment.")
                   |> assign(
                     reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
                     reply_media_alt: media_alt,
                     reply_options_open?: reply_options_open?,
                     reply_cw_open?: reply_cw_open?
                   )}

                nil ->
                  case Publish.post_note(user, content,
                         in_reply_to: in_reply_to,
                         attachments: attachments,
                         visibility: visibility,
                         spoiler_text: spoiler_text,
                         sensitive: sensitive,
                         language: language
                       ) do
                    {:ok, _reply} ->
                      {:noreply,
                       socket
                       |> put_flash(:info, "Reply posted.")
                       |> assign(
                         reply_modal_open?: false,
                         reply_to_ap_id: nil,
                         reply_to_handle: nil,
                         reply_form:
                           Phoenix.Component.to_form(default_reply_params(), as: :reply),
                         reply_media_alt: %{},
                         reply_options_open?: false,
                         reply_cw_open?: false
                       )
                       |> push_event("reply_modal_close", %{})}

                    {:error, :too_long} ->
                      {:noreply,
                       socket
                       |> put_flash(:error, "Reply is too long.")
                       |> assign(
                         reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
                         reply_media_alt: media_alt,
                         reply_options_open?: reply_options_open?,
                         reply_cw_open?: reply_cw_open?
                       )}

                    {:error, :empty} ->
                      {:noreply,
                       socket
                       |> put_flash(:error, "Reply can't be empty.")
                       |> assign(
                         reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
                         reply_media_alt: media_alt,
                         reply_options_open?: reply_options_open?,
                         reply_cw_open?: reply_cw_open?
                       )}

                    _ ->
                      {:noreply,
                       socket
                       |> put_flash(:error, "Could not post reply.")
                       |> assign(
                         reply_form: Phoenix.Component.to_form(reply_params, as: :reply),
                         reply_media_alt: media_alt,
                         reply_options_open?: reply_options_open?,
                         reply_cw_open?: reply_cw_open?
                       )}
                  end
              end
          end
        else
          {:noreply, put_flash(socket, :error, "Select a post to reply to.")}
        end
    end
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    cursor = socket.assigns.dm_cursor

    cond do
      socket.assigns.dm_end? ->
        {:noreply, socket}

      is_nil(cursor) ->
        {:noreply, assign(socket, dm_end?: true)}

      true ->
        messages =
          DirectMessages.list_for_user(socket.assigns.current_user,
            limit: @page_size,
            max_id: cursor
          )

        socket =
          if messages == [] do
            assign(socket, dm_end?: true)
          else
            current_user = socket.assigns.current_user
            new_cursor = cursor(messages)
            dm_end? = length(messages) < @page_size

            Enum.reduce(StatusVM.decorate_many(messages, current_user), socket, fn entry,
                                                                                   socket ->
              stream_insert(socket, :messages, entry, at: -1)
            end)
            |> assign(dm_cursor: new_cursor, dm_end?: dm_end?)
          end

        {:noreply, socket}
    end
  end

  def handle_event("send_dm", %{"dm" => %{} = params}, socket) do
    recipient = params |> Map.get("recipient", "") |> to_string() |> String.trim()
    body = params |> Map.get("content", "") |> to_string() |> String.trim()
    e2ee_dm = params |> Map.get("e2ee_dm", "") |> to_string() |> String.trim()

    cond do
      not match?(%User{}, socket.assigns.current_user) ->
        {:noreply, put_flash(socket, :error, "Sign in to send messages.")}

      recipient == "" ->
        {:noreply, put_flash(socket, :error, "Pick a recipient.")}

      body == "" ->
        {:noreply, put_flash(socket, :error, "Message can't be empty.")}

      true ->
        {content, opts} = prepare_dm(recipient, body, e2ee_dm)

        case Publish.post_note(socket.assigns.current_user, content, opts) do
          {:ok, create} ->
            note = Objects.get_by_ap_id(create.object)

            socket =
              socket
              |> put_flash(:info, "Message sent.")
              |> assign(
                dm_form:
                  Phoenix.Component.to_form(
                    %{"recipient" => recipient, "content" => "", "e2ee_dm" => ""},
                    as: :dm
                  )
              )

            if note do
              {:noreply,
               stream_insert(
                 socket,
                 :messages,
                 StatusVM.decorate(note, socket.assigns.current_user),
                 at: 0
               )}
            else
              {:noreply, socket}
            end

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not send message.")}
        end
    end
  end

  def handle_event("send_dm", _params, socket) do
    {:noreply, put_flash(socket, :error, "Could not send message.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <AppShell.app_shell
        id="messages-shell"
        nav_id="messages-nav"
        main_id="messages-main"
        active={:messages}
        current_user={@current_user}
        notifications_count={@notifications_count}
      >
        <section class="space-y-4">
          <.card class="p-6">
            <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
              Messages
            </p>
            <h2 class="mt-2 text-2xl font-bold text-[color:var(--text-primary)]">
              Direct
            </h2>
          </.card>

          <%= if @current_user do %>
            <.card class="p-6">
              <.form
                for={@dm_form}
                id="dm-form"
                phx-submit="send_dm"
                phx-hook="E2EEDMComposer"
                data-role="dm-composer"
                data-user-ap-id={@current_user.ap_id}
                class="space-y-4"
              >
                <input
                  type="text"
                  name="dm[e2ee_dm]"
                  value={@dm_form.params["e2ee_dm"] || ""}
                  data-role="dm-e2ee-payload"
                  class="hidden"
                  aria-hidden="true"
                  tabindex="-1"
                />

                <p
                  data-role="dm-e2ee-feedback"
                  class="hidden border border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] px-3 py-2 text-sm text-[color:var(--text-secondary)]"
                >
                </p>

                <div class="space-y-2">
                  <label class="block text-sm font-bold text-[color:var(--text-primary)]">
                    To
                  </label>
                  <input
                    type="text"
                    name="dm[recipient]"
                    value={@dm_form.params["recipient"] || ""}
                    placeholder="@alice or @alice@remote.example"
                    class="w-full border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-sm text-[color:var(--text-primary)] focus:outline-none focus-brutal placeholder:text-[color:var(--text-muted)]"
                  />
                </div>

                <div class="space-y-2">
                  <label class="block text-sm font-bold text-[color:var(--text-primary)]">
                    Message
                  </label>
                  <textarea
                    name="dm[content]"
                    rows="4"
                    placeholder="Write a direct message…"
                    class="w-full resize-none border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 text-sm text-[color:var(--text-primary)] focus:outline-none focus-brutal placeholder:text-[color:var(--text-muted)]"
                  ><%= @dm_form.params["content"] || "" %></textarea>
                </div>

                <div class="flex justify-end">
                  <.button type="submit" phx-disable-with="Sending...">
                    Send
                  </.button>
                </div>
              </.form>
            </.card>

            <div
              id="messages-list"
              phx-update="stream"
              data-role="messages-list"
              class="space-y-4"
            >
              <div
                id="messages-empty"
                class="hidden only:block border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] p-6 text-sm text-[color:var(--text-secondary)]"
              >
                No direct messages yet.
              </div>

              <StatusCard.status_card
                :for={{id, entry} <- @streams.messages}
                id={id}
                entry={entry}
                current_user={@current_user}
                reply_mode={:modal}
              />
            </div>

            <div :if={!@dm_end?} class="flex justify-center py-2">
              <.button
                data-role="messages-load-more"
                phx-click={JS.show(to: "#messages-loading-more") |> JS.push("load_more")}
                phx-disable-with="Loading..."
                aria-label="Load more messages"
                variant="secondary"
              >
                <.icon name="hero-chevron-down" class="size-4" /> Load more
              </.button>
            </div>

            <div
              :if={!@dm_end?}
              id="messages-loading-more"
              data-role="messages-loading-more"
              class="hidden space-y-4"
              aria-hidden="true"
            >
              <.skeleton_status_card
                :for={_ <- 1..2}
                class="border-2 border-[color:var(--border-default)]"
              />
            </div>
          <% else %>
            <.card class="p-6">
              <p
                data-role="messages-auth-required"
                class="text-sm text-[color:var(--text-secondary)]"
              >
                Sign in to view direct messages.
              </p>
              <div class="mt-4 flex flex-wrap items-center gap-2">
                <.button navigate={~p"/login"} size="sm">Login</.button>
                <.button navigate={~p"/register"} size="sm" variant="secondary">Register</.button>
              </div>
            </.card>
          <% end %>
        </section>
      </AppShell.app_shell>

      <ReplyModal.reply_modal
        :if={@current_user}
        form={@reply_form}
        upload={@uploads.reply_media}
        media_alt={@reply_media_alt}
        reply_to_handle={@reply_to_handle}
        mention_suggestions={@mention_suggestions}
        options_open?={@reply_options_open?}
        cw_open?={@reply_cw_open?}
        open={@reply_modal_open?}
      />
    </Layouts.app>
    """
  end

  defp include_dm?(%{type: "Note"} = note, %User{} = current_user) do
    DirectMessages.direct?(note) and Objects.visible_to?(note, current_user)
  end

  defp include_dm?(_note, _current_user), do: false

  defp cursor([]), do: nil

  defp cursor(messages) when is_list(messages) do
    case List.last(messages) do
      %{id: id} when is_integer(id) -> id
      _ -> nil
    end
  end

  defp message_dom_id(%{object: %{id: id}}) when is_integer(id), do: "dm-#{id}"
  defp message_dom_id(_), do: Ecto.UUID.generate()

  defp normalize_dm_content(recipient, body) when is_binary(recipient) and is_binary(body) do
    recipient =
      recipient
      |> String.trim()
      |> String.trim_leading("@")

    if recipient == "" do
      body
    else
      "@" <> recipient <> " " <> body
    end
  end

  defp prepare_dm(recipient, body, e2ee_dm) when is_binary(recipient) and is_binary(body) do
    e2ee_dm = if is_binary(e2ee_dm), do: String.trim(e2ee_dm), else: ""

    with true <- e2ee_dm != "",
         {:ok, %{} = payload} <- Jason.decode(e2ee_dm) do
      content = normalize_dm_content(recipient, "Encrypted message")
      {content, visibility: "direct", e2ee_dm: payload}
    else
      _ ->
        content = normalize_dm_content(recipient, body)
        {content, visibility: "direct"}
    end
  end

  defp notifications_count(nil), do: 0

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: 20)
    |> length()
  end

  defp default_reply_params do
    %{
      "content" => "",
      "spoiler_text" => "",
      "visibility" => "direct",
      "sensitive" => "false",
      "language" => "",
      "ui_options_open" => "false",
      "media_alt" => %{}
    }
  end
end
