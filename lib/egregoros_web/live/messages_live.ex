defmodule EgregorosWeb.MessagesLive do
  use EgregorosWeb, :live_view

  alias Egregoros.CustomEmojis
  alias Egregoros.DirectMessages
  alias Egregoros.HTML
  alias Egregoros.Notifications
  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.User
  alias Egregoros.Users
  alias EgregorosWeb.ViewModels.Actor

  @conversations_page_size 40
  @messages_page_size 40
  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @recipient_fields ~w(to cc bto bcc audience)

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case Map.get(session, "user_id") do
        nil -> nil
        id -> Users.get(id)
      end

    if connected?(socket) and match?(%User{}, current_user) do
      Phoenix.PubSub.subscribe(
        Egregoros.PubSub,
        Egregoros.Timeline.user_topic(current_user.ap_id)
      )
    end

    conversations = conversations_for_user(current_user)

    selected_peer_ap_id =
      case conversations do
        [%{peer: %{ap_id: ap_id}} | _] when is_binary(ap_id) and ap_id != "" -> ap_id
        _ -> nil
      end

    selected_peer =
      if is_binary(selected_peer_ap_id), do: Actor.card(selected_peer_ap_id), else: nil

    messages =
      case {current_user, selected_peer_ap_id} do
        {%User{}, ap_id} when is_binary(ap_id) and ap_id != "" ->
          current_user
          |> DirectMessages.list_conversation(ap_id, limit: @messages_page_size)
          |> Enum.reverse()

        _ ->
          []
      end

    conversation_e2ee? = Enum.any?(messages, &encrypted_message?/1)

    recipient =
      case selected_peer do
        %{handle: handle} when is_binary(handle) -> handle
        _ -> ""
      end

    dm_form =
      Phoenix.Component.to_form(%{"recipient" => recipient, "content" => "", "e2ee_dm" => ""},
        as: :dm
      )

    {:ok,
     socket
     |> assign(
       current_user: current_user,
       notifications_count: notifications_count(current_user),
       selected_peer_ap_id: selected_peer_ap_id,
       selected_peer: selected_peer,
       conversation_e2ee?: conversation_e2ee?,
       dm_form: dm_form
     )
     |> stream(:conversations, conversations, dom_id: &conversation_dom_id/1)
     |> stream(:chat_messages, messages, dom_id: &message_dom_id/1)}
  end

  @impl true
  def handle_info({:post_created, post}, socket) do
    case socket.assigns.current_user do
      %User{} = user ->
        if include_dm?(post, user) do
          peer_ap_id = peer_ap_id_for_dm(post, user.ap_id)

          socket =
            socket
            |> stream(:conversations, conversations_for_user(user), reset: true)

          socket =
            if is_binary(peer_ap_id) and peer_ap_id == socket.assigns.selected_peer_ap_id do
              socket
              |> stream_insert(:chat_messages, post, at: -1)
              |> then(fn socket ->
                if encrypted_message?(post),
                  do: assign(socket, :conversation_e2ee?, true),
                  else: socket
              end)
            else
              socket
            end

          {:noreply, socket}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_conversation", %{"peer" => peer_ap_id}, socket) do
    peer_ap_id = peer_ap_id |> to_string() |> String.trim()

    case socket.assigns.current_user do
      %User{} = user when peer_ap_id != "" ->
        selected_peer = Actor.card(peer_ap_id)

        recipient =
          case selected_peer do
            %{handle: handle} when is_binary(handle) -> handle
            _ -> ""
          end

        dm_form =
          Phoenix.Component.to_form(%{"recipient" => recipient, "content" => "", "e2ee_dm" => ""},
            as: :dm
          )

        messages =
          user
          |> DirectMessages.list_conversation(peer_ap_id, limit: @messages_page_size)
          |> Enum.reverse()

        conversation_e2ee? = Enum.any?(messages, &encrypted_message?/1)

        {:noreply,
         socket
         |> assign(
           selected_peer_ap_id: peer_ap_id,
           selected_peer: selected_peer,
           conversation_e2ee?: conversation_e2ee?,
           dm_form: dm_form
         )
         |> stream(:chat_messages, messages, reset: true)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("select_conversation", _params, socket), do: {:noreply, socket}

  @impl true
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
            message = Objects.get_by_ap_id(create.object)

            {peer_ap_id, selected_peer} =
              case {socket.assigns.current_user, message} do
                {%User{ap_id: ap_id}, %{} = message} when is_binary(ap_id) ->
                  peer_ap_id = peer_ap_id_for_dm(message, ap_id)

                  selected_peer =
                    if is_binary(peer_ap_id) and peer_ap_id != "" do
                      Actor.card(peer_ap_id)
                    else
                      nil
                    end

                  {peer_ap_id, selected_peer}

                _ ->
                  {nil, nil}
              end

            recipient =
              case selected_peer do
                %{handle: handle} when is_binary(handle) -> handle
                _ -> recipient
              end

            dm_form =
              Phoenix.Component.to_form(
                %{"recipient" => recipient, "content" => "", "e2ee_dm" => ""},
                as: :dm
              )

            conversations = conversations_for_user(socket.assigns.current_user)

            socket =
              socket
              |> put_flash(:info, "Message sent.")
              |> assign(
                selected_peer_ap_id: peer_ap_id,
                selected_peer: selected_peer,
                dm_form: dm_form
              )
              |> stream(:conversations, conversations, reset: true)

            socket =
              if is_binary(peer_ap_id) and peer_ap_id != "" do
                messages =
                  socket.assigns.current_user
                  |> DirectMessages.list_conversation(peer_ap_id, limit: @messages_page_size)
                  |> Enum.reverse()

                socket
                |> assign(:conversation_e2ee?, Enum.any?(messages, &encrypted_message?/1))
                |> stream(:chat_messages, messages, reset: true)
              else
                assign(socket, :conversation_e2ee?, false)
              end

            {:noreply, socket}

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
          <%= if @current_user do %>
            <div class="grid gap-4 lg:grid-cols-[18rem_1fr]">
              <aside class="border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]">
                <header class="flex items-center justify-between border-b-2 border-[color:var(--border-default)] px-4 py-3">
                  <h2 class="text-xs font-bold uppercase tracking-widest text-[color:var(--text-muted)]">
                    Messages
                  </h2>
                  <button
                    type="button"
                    class="border-2 border-[color:var(--border-default)] bg-[color:var(--text-primary)] px-2 py-1 text-xs font-bold uppercase text-[color:var(--bg-base)] transition hover:shadow-[3px_3px_0_var(--border-default)] hover:-translate-x-0.5 hover:-translate-y-0.5"
                  >
                    + New
                  </button>
                </header>

                <div data-role="dm-conversations" class="max-h-[70vh] overflow-y-auto">
                  <button
                    :for={{id, conversation} <- @streams.conversations}
                    id={id}
                    type="button"
                    data-role="dm-conversation"
                    data-peer-handle={conversation.peer.handle}
                    phx-click="select_conversation"
                    phx-value-peer={conversation.peer.ap_id}
                    class={[
                      "flex w-full items-start gap-3 border-b border-[color:var(--border-muted)] px-4 py-4 text-left transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal",
                      conversation.peer.ap_id == @selected_peer_ap_id &&
                        "bg-[color:var(--bg-subtle)] border-l-4 border-l-[color:var(--text-primary)] pl-3"
                    ]}
                  >
                    <span class="mt-0.5 inline-flex h-9 w-9 shrink-0 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] font-bold">
                      {avatar_initial(conversation.peer.display_name)}
                    </span>
                    <span class="min-w-0 flex-1">
                      <span class="block truncate font-bold text-[color:var(--text-primary)]">
                        {conversation.peer.display_name}
                      </span>
                      <span class="mt-0.5 block truncate font-mono text-xs text-[color:var(--text-muted)]">
                        {conversation.peer.handle}
                      </span>
                    </span>
                  </button>
                </div>
              </aside>

              <main class="flex min-h-[70vh] flex-col border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)]">
                <header class="flex items-center justify-between border-b-2 border-[color:var(--border-default)] px-5 py-4">
                  <%= if @selected_peer do %>
                    <div class="flex min-w-0 items-center gap-3">
                      <span class="inline-flex h-10 w-10 shrink-0 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] font-bold">
                        {avatar_initial(@selected_peer.display_name)}
                      </span>
                      <div class="min-w-0">
                        <p class="truncate font-bold text-[color:var(--text-primary)]">
                          {@selected_peer.display_name}
                        </p>
                        <p
                          data-role="dm-chat-peer-handle"
                          class="truncate font-mono text-xs text-[color:var(--text-muted)]"
                        >
                          {@selected_peer.handle}
                        </p>
                      </div>
                    </div>

                    <span
                      :if={@conversation_e2ee?}
                      data-role="dm-e2ee-badge"
                      class="inline-flex items-center gap-2 border border-[color:var(--success)] bg-[color:var(--success-subtle)] px-3 py-1 font-mono text-[10px] font-bold uppercase tracking-widest text-[color:var(--success)]"
                    >
                      <.icon name="hero-lock-closed" class="size-4" /> E2EE
                    </span>
                  <% else %>
                    <div class="min-w-0">
                      <p class="font-bold text-[color:var(--text-primary)]">New encrypted chat</p>
                      <p class="font-mono text-xs text-[color:var(--text-muted)]">
                        Pick a recipient to start.
                      </p>
                    </div>

                    <span
                      :if={@conversation_e2ee?}
                      data-role="dm-e2ee-badge"
                      class="inline-flex items-center gap-2 border border-[color:var(--success)] bg-[color:var(--success-subtle)] px-3 py-1 font-mono text-[10px] font-bold uppercase tracking-widest text-[color:var(--success)]"
                    >
                      <.icon name="hero-shield-check" class="size-4" /> E2EE
                    </span>
                  <% end %>
                </header>

                <div
                  data-role="dm-chat-messages"
                  id="dm-chat-messages"
                  phx-update="stream"
                  class="flex-1 space-y-4 overflow-y-auto bg-[color:var(--bg-subtle)] p-5"
                >
                  <div
                    id="dm-chat-empty"
                    class="hidden only:flex flex-col items-center justify-center gap-3 border-2 border-dashed border-[color:var(--border-muted)] bg-[color:var(--bg-base)] p-8 text-center"
                  >
                    <span class="inline-flex h-14 w-14 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--bg-subtle)] text-2xl">
                      <.icon name="hero-chat-bubble-left-right" class="size-8" />
                    </span>
                    <p class="font-bold text-[color:var(--text-primary)]">No messages yet</p>
                    <p class="text-sm text-[color:var(--text-muted)]">
                      Start a conversation by sending an encrypted message below.
                    </p>
                  </div>

                  <div
                    :for={{id, message} <- @streams.chat_messages}
                    id={id}
                    data-role="dm-message"
                    data-kind={if message.actor == @current_user.ap_id, do: "sent", else: "received"}
                    class={[
                      "flex gap-3",
                      message.actor == @current_user.ap_id && "flex-row-reverse ml-auto"
                    ]}
                  >
                    <span class="mt-1 inline-flex h-8 w-8 shrink-0 items-center justify-center border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] text-xs font-bold">
                      {if message.actor == @current_user.ap_id,
                        do: avatar_initial(@current_user.nickname),
                        else: avatar_initial(@selected_peer && @selected_peer.display_name)}
                    </span>

                    <div class={[
                      "max-w-[75%] space-y-1",
                      message.actor == @current_user.ap_id && "items-end text-right"
                    ]}>
                      <div class={[
                        "border-2 border-[color:var(--border-default)] px-4 py-3",
                        message.actor == @current_user.ap_id &&
                          "bg-[color:var(--text-primary)] text-[color:var(--bg-base)]",
                        message.actor != @current_user.ap_id &&
                          "bg-[color:var(--bg-base)] text-[color:var(--text-primary)] shadow-[3px_3px_0_var(--border-default)]"
                      ]}>
                        <.dm_message_body message={message} current_user={@current_user} />
                      </div>

                      <div class="flex items-center gap-2 font-mono text-[10px] font-bold uppercase tracking-widest text-[color:var(--text-muted)]">
                        <.icon
                          :if={encrypted_message?(message)}
                          name="hero-lock-closed"
                          class="size-3"
                        />
                        <span>{message_timestamp(message)}</span>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="border-t-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-5 py-4">
                  <.form
                    for={@dm_form}
                    id="dm-form"
                    phx-submit="send_dm"
                    phx-hook="E2EEDMComposer"
                    data-role="dm-composer"
                    data-user-ap-id={@current_user.ap_id}
                    class="space-y-3"
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

                    <input
                      type="text"
                      name="dm[recipient]"
                      value={@dm_form.params["recipient"] || ""}
                      placeholder="@alice or @alice@remote.example"
                      class={[
                        "w-full border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 font-mono text-sm text-[color:var(--text-primary)] focus:outline-none focus-brutal placeholder:text-[color:var(--text-muted)]",
                        @selected_peer && "hidden"
                      ]}
                    />

                    <div class="flex items-end gap-3">
                      <div class="relative flex-1">
                        <textarea
                          name="dm[content]"
                          rows="2"
                          placeholder={
                            if(@conversation_e2ee?,
                              do: "Type an encrypted message...",
                              else: "Type a message..."
                            )
                          }
                          class="w-full resize-none border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] px-3 py-2 pr-10 text-sm text-[color:var(--text-primary)] focus:outline-none focus-brutal placeholder:text-[color:var(--text-muted)]"
                        ><%= @dm_form.params["content"] || "" %></textarea>
                        <span
                          :if={@conversation_e2ee?}
                          class="pointer-events-none absolute bottom-3 right-3 text-[color:var(--success)]"
                        >
                          <.icon name="hero-lock-closed" class="size-5" />
                        </span>
                      </div>

                      <.button type="submit" phx-disable-with="Sending..." aria-label="Send message">
                        <.icon name="hero-paper-airplane" class="size-4" />
                      </.button>
                    </div>
                  </.form>
                </div>
              </main>
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
    </Layouts.app>
    """
  end

  attr :message, :map, required: true
  attr :current_user, :any, default: nil

  defp dm_message_body(assigns) do
    ~H"""
    <% e2ee_payload = e2ee_payload_json(@message) %>
    <% current_user_ap_id = current_user_ap_id(@current_user) %>

    <div
      id={
        if is_integer(@message.id), do: "dm-message-body-#{@message.id}", else: Ecto.UUID.generate()
      }
      data-role="dm-message-body"
      data-e2ee-dm={e2ee_payload}
      data-current-user-ap-id={current_user_ap_id}
      phx-hook={if is_binary(e2ee_payload), do: "E2EEDMMessage", else: nil}
      class={is_binary(e2ee_payload) && "whitespace-pre-wrap"}
    >
      <%= if is_binary(e2ee_payload) do %>
        <div data-role="e2ee-dm-body">{dm_content_html(@message)}</div>
        <div data-role="e2ee-dm-actions" class="mt-3">
          <button
            type="button"
            data-role="e2ee-dm-unlock"
            class="inline-flex cursor-pointer items-center gap-2 border border-[color:var(--border-default)] bg-transparent px-3 py-1.5 font-mono text-[10px] font-bold uppercase tracking-widest text-[color:var(--text-primary)] transition hover:bg-[color:var(--text-primary)] hover:text-[color:var(--bg-base)] focus-visible:outline-none focus-brutal"
          >
            <.icon name="hero-lock-open" class="size-4" /> Unlock
          </button>
        </div>
      <% else %>
        {dm_content_html(@message)}
      <% end %>
    </div>
    """
  end

  defp conversations_for_user(%User{} = user) do
    user
    |> DirectMessages.list_for_user(limit: @conversations_page_size)
    |> Enum.reduce({[], MapSet.new()}, fn message, {acc, seen} ->
      peer_ap_id = peer_ap_id_for_dm(message, user.ap_id)

      if is_binary(peer_ap_id) and peer_ap_id != "" and not MapSet.member?(seen, peer_ap_id) do
        peer = Actor.card(peer_ap_id)
        {[{peer_ap_id, %{peer: peer, last_message: message}} | acc], MapSet.put(seen, peer_ap_id)}
      else
        {acc, seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(fn {_peer_ap_id, conversation} -> conversation end)
  end

  defp conversations_for_user(_user), do: []

  defp peer_ap_id_for_dm(%{actor: actor} = message, current_user_ap_id)
       when is_binary(actor) and is_binary(current_user_ap_id) do
    actor = String.trim(actor)

    cond do
      actor == "" ->
        nil

      actor == current_user_ap_id ->
        message
        |> dm_recipient_ap_ids()
        |> Enum.reject(&(&1 == current_user_ap_id))
        |> List.first()

      true ->
        actor
    end
  end

  defp peer_ap_id_for_dm(_message, _current_user_ap_id), do: nil

  defp dm_recipient_ap_ids(%{data: %{} = data}), do: dm_recipient_ap_ids(data)

  defp dm_recipient_ap_ids(%{} = data) do
    followers =
      data
      |> Map.get("actor")
      |> case do
        actor when is_binary(actor) and actor != "" -> actor <> "/followers"
        _ -> nil
      end

    @recipient_fields
    |> Enum.flat_map(fn field ->
      data
      |> Map.get(field, [])
      |> List.wrap()
      |> Enum.map(&extract_recipient_id/1)
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn value ->
      value == "" or value == @as_public or value == followers or
        String.ends_with?(value, "/followers")
    end)
    |> Enum.uniq()
  end

  defp dm_recipient_ap_ids(_data), do: []

  defp extract_recipient_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_recipient_id(%{id: id}) when is_binary(id), do: id
  defp extract_recipient_id(id) when is_binary(id), do: id
  defp extract_recipient_id(_recipient), do: nil

  defp include_dm?(%{type: type} = note, %User{} = current_user)
       when type in ["Note", "EncryptedMessage"] do
    DirectMessages.direct?(note) and Objects.visible_to?(note, current_user)
  end

  defp include_dm?(_note, _current_user), do: false

  defp conversation_dom_id(%{peer: %{ap_id: ap_id}}) when is_binary(ap_id) do
    "dm-conversation-#{:erlang.phash2(ap_id)}"
  end

  defp conversation_dom_id(_conversation), do: Ecto.UUID.generate()

  defp message_dom_id(%{id: id}) when is_integer(id), do: "dm-message-#{id}"
  defp message_dom_id(_message), do: Ecto.UUID.generate()

  defp avatar_initial(name) when is_binary(name) do
    name = String.trim(name)

    case String.first(name) do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp avatar_initial(_), do: "?"

  defp e2ee_payload_json(%{data: %{} = data}) do
    case Map.get(data, "egregoros:e2ee_dm") do
      %{} = payload when map_size(payload) > 0 -> Jason.encode!(payload)
      _ -> nil
    end
  end

  defp e2ee_payload_json(_message), do: nil

  defp encrypted_message?(%{data: %{} = data}) do
    case Map.get(data, "egregoros:e2ee_dm") do
      %{} = payload -> map_size(payload) > 0
      _ -> false
    end
  end

  defp encrypted_message?(_message), do: false

  defp current_user_ap_id(%{ap_id: ap_id}) when is_binary(ap_id), do: ap_id
  defp current_user_ap_id(_current_user), do: ""

  defp dm_content_html(%{data: %{} = data} = object) do
    raw = Map.get(data, "content", "")
    emojis = CustomEmojis.from_object(object)
    ap_tags = Map.get(data, "tag", [])

    raw
    |> HTML.to_safe_html(format: :html, emojis: emojis, ap_tags: ap_tags)
    |> Phoenix.HTML.raw()
  end

  defp dm_content_html(_message), do: ""

  defp message_timestamp(%{published: %DateTime{} = published}) do
    published
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  defp message_timestamp(_message), do: "now"

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
end
