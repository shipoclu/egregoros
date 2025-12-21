defmodule PleromaReduxWeb.TimelineLive do
  use PleromaReduxWeb, :live_view

  alias PleromaRedux.Interactions
  alias PleromaRedux.Media
  alias PleromaRedux.MediaStorage
  alias PleromaRedux.Notifications
  alias PleromaRedux.Objects
  alias PleromaRedux.Publish
  alias PleromaRedux.Relationships
  alias PleromaRedux.Timeline
  alias PleromaRedux.User
  alias PleromaRedux.Users
  alias PleromaReduxWeb.ViewModels.Status, as: StatusVM

  @page_size 20
  @compose_max_chars 5000

  @impl true
  def mount(params, session, socket) do
    if connected?(socket) do
      Timeline.subscribe()
    end

    current_user =
      case Map.get(session, "user_id") do
        nil -> nil
        id -> Users.get(id)
      end

    timeline = timeline_from_params(params, current_user)

    form = Phoenix.Component.to_form(default_post_params(), as: :post)

    posts = list_timeline_posts(timeline, current_user, limit: @page_size)

    socket =
      socket
      |> assign(
        timeline: timeline,
        home_actor_ids: home_actor_ids(current_user),
        notifications_count: notifications_count(current_user),
        compose_open?: false,
        compose_options_open?: false,
        compose_cw_open?: false,
        error: nil,
        pending_posts: [],
        timeline_at_top?: true,
        form: form,
        media_alt: %{},
        posts_cursor: posts_cursor(posts),
        posts_end?: length(posts) < @page_size,
        current_user: current_user
      )
      |> stream(:posts, StatusVM.decorate_many(posts, current_user), dom_id: &post_dom_id/1)
      |> allow_upload(:media,
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

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    timeline = timeline_from_params(params, socket.assigns.current_user)

    socket =
      if timeline == socket.assigns.timeline do
        socket
      else
        posts = list_timeline_posts(timeline, socket.assigns.current_user, limit: @page_size)

        socket
        |> assign(
          timeline: timeline,
          pending_posts: [],
          timeline_at_top?: true,
          posts_cursor: posts_cursor(posts),
          posts_end?: length(posts) < @page_size
        )
        |> stream(:posts, StatusVM.decorate_many(posts, socket.assigns.current_user),
          reset: true,
          dom_id: &post_dom_id/1
        )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("compose_change", %{"post" => %{} = post_params}, socket) do
    post_params = Map.merge(default_post_params(), post_params)
    media_alt = Map.get(post_params, "media_alt", %{})

    compose_options_open? = truthy?(Map.get(post_params, "ui_options_open"))

    compose_cw_open? =
      socket.assigns.compose_cw_open? ||
        post_params |> Map.get("spoiler_text", "") |> to_string() |> String.trim() != ""

    {:noreply,
     assign(socket,
       form: Phoenix.Component.to_form(post_params, as: :post),
       media_alt: media_alt,
       compose_options_open?: compose_options_open?,
       compose_cw_open?: compose_cw_open?
     )}
  end

  def handle_event("open_compose", _params, socket) do
    {:noreply, assign(socket, compose_open?: true)}
  end

  def handle_event("close_compose", _params, socket) do
    {:noreply, assign(socket, compose_open?: false)}
  end

  def handle_event("toggle_compose_cw", _params, socket) do
    if socket.assigns.compose_cw_open? do
      post_params =
        default_post_params()
        |> Map.merge(socket.assigns.form.params)
        |> Map.put("spoiler_text", "")

      {:noreply,
       assign(socket,
         compose_cw_open?: false,
         form: Phoenix.Component.to_form(post_params, as: :post)
       )}
    else
      {:noreply, assign(socket, compose_cw_open?: true)}
    end
  end

  def handle_event("timeline_at_top", %{"at_top" => at_top}, socket) do
    at_top? = truthy?(at_top)

    socket =
      socket
      |> assign(:timeline_at_top?, at_top?)
      |> maybe_flush_pending_posts(at_top?)

    {:noreply, socket}
  end

  def handle_event("copied_link", _params, socket) do
    {:noreply, put_flash(socket, :info, "Copied link to clipboard.")}
  end

  def handle_event("cancel_media", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:media, ref)
     |> assign(:media_alt, Map.delete(socket.assigns.media_alt, ref))}
  end

  def handle_event("create_post", %{"post" => %{} = post_params}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, assign(socket, error: "Register to post.")}

      user ->
        post_params = Map.merge(default_post_params(), post_params)
        content = post_params |> Map.get("content", "") |> to_string()
        media_alt = Map.get(post_params, "media_alt", %{})
        visibility = Map.get(post_params, "visibility", "public")
        spoiler_text = Map.get(post_params, "spoiler_text")
        sensitive = Map.get(post_params, "sensitive")
        language = Map.get(post_params, "language")

        upload = socket.assigns.uploads.media

        cond do
          Enum.any?(upload.entries, &(!&1.done?)) ->
            {:noreply,
             assign(socket,
               error: "Wait for attachments to finish uploading.",
               form: Phoenix.Component.to_form(post_params, as: :post),
               media_alt: media_alt
             )}

          upload.errors != [] or Enum.any?(upload.entries, &(!&1.valid?)) ->
            {:noreply,
             assign(socket,
               error: "Remove invalid attachments before posting.",
               form: Phoenix.Component.to_form(post_params, as: :post),
               media_alt: media_alt
             )}

          true ->
            attachments =
              consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
                upload = %Plug.Upload{
                  path: path,
                  filename: entry.client_name,
                  content_type: entry.client_type
                }

                description = media_alt |> Map.get(entry.ref, "") |> to_string() |> String.trim()

                with {:ok, url_path} <- MediaStorage.store_media(user, upload),
                     {:ok, object} <-
                       Media.create_media_object(user, upload, url_path, description: description) do
                  {:ok, object.data}
                else
                  {:error, reason} -> {:ok, {:error, reason}}
                end
              end)

            case Enum.find(attachments, &match?({:error, _}, &1)) do
              {:error, _reason} ->
                {:noreply,
                 assign(socket,
                   error: "Could not upload attachment.",
                   form: Phoenix.Component.to_form(post_params, as: :post),
                   media_alt: media_alt
                 )}

              nil ->
                case Publish.post_note(user, content,
                       attachments: attachments,
                       visibility: visibility,
                       spoiler_text: spoiler_text,
                       sensitive: sensitive,
                       language: language
                     ) do
                  {:ok, _post} ->
                    {:noreply,
                     assign(socket,
                       form: Phoenix.Component.to_form(default_post_params(), as: :post),
                       compose_open?: false,
                       compose_options_open?: false,
                       compose_cw_open?: false,
                       error: nil,
                       media_alt: %{}
                     )}

                  {:error, :too_long} ->
                    {:noreply,
                     assign(socket,
                       error: "Post is too long.",
                       form: Phoenix.Component.to_form(post_params, as: :post),
                       media_alt: media_alt
                     )}

                  {:error, :empty} ->
                    {:noreply,
                     assign(socket,
                       error: "Post can't be empty.",
                       form: Phoenix.Component.to_form(post_params, as: :post),
                       media_alt: media_alt
                     )}
                end
            end
        end
    end
  end

  def handle_event("toggle_like", %{"id" => id}, socket) do
    with %User{} = user <- socket.assigns.current_user,
         {post_id, ""} <- Integer.parse(to_string(id)) do
      _ = Interactions.toggle_like(user, post_id)

      {:noreply, refresh_post(socket, post_id)}
    else
      nil ->
        {:noreply, assign(socket, error: "Register to like posts.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_repost", %{"id" => id}, socket) do
    with %User{} = user <- socket.assigns.current_user,
         {post_id, ""} <- Integer.parse(to_string(id)) do
      _ = Interactions.toggle_repost(user, post_id)

      {:noreply, refresh_post(socket, post_id)}
    else
      nil ->
        {:noreply, assign(socket, error: "Register to repost.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_reaction", %{"id" => id, "emoji" => emoji}, socket) do
    with %User{} = user <- socket.assigns.current_user,
         {post_id, ""} <- Integer.parse(to_string(id)) do
      emoji = to_string(emoji)
      _ = Interactions.toggle_reaction(user, post_id, emoji)

      {:noreply, refresh_post(socket, post_id)}
    else
      nil ->
        {:noreply, assign(socket, error: "Register to react.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_post", %{"id" => id}, socket) do
    with %User{} = user <- socket.assigns.current_user,
         {post_id, ""} <- Integer.parse(to_string(id)),
         {:ok, _delete} <- Interactions.delete_post(user, post_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Post deleted.")
       |> stream_delete(:posts, %{object: %{id: post_id}})}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Register to delete posts.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not delete post.")}
    end
  end

  def handle_event("load_more", _params, socket) do
    cursor = socket.assigns.posts_cursor

    cond do
      socket.assigns.posts_end? ->
        {:noreply, socket}

      is_nil(cursor) ->
        {:noreply, assign(socket, posts_end?: true)}

      true ->
        posts =
          list_timeline_posts(socket.assigns.timeline, socket.assigns.current_user,
            limit: @page_size,
            max_id: cursor
          )

        socket =
          if posts == [] do
            assign(socket, posts_end?: true)
          else
            new_cursor = posts_cursor(posts)
            posts_end? = length(posts) < @page_size
            current_user = socket.assigns.current_user

            Enum.reduce(StatusVM.decorate_many(posts, current_user), socket, fn entry, socket ->
              stream_insert(socket, :posts, entry, at: -1)
            end)
            |> assign(posts_cursor: new_cursor, posts_end?: posts_end?)
          end

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:post_created, post}, socket) do
    if include_post?(post, socket.assigns.timeline, socket.assigns.home_actor_ids) do
      if socket.assigns.timeline_at_top? do
        cursor =
          case socket.assigns.posts_cursor do
            nil -> post.id
            existing -> min(existing, post.id)
          end

        {:noreply,
         socket
         |> stream_insert(:posts, StatusVM.decorate(post, socket.assigns.current_user), at: 0)
         |> assign(:posts_cursor, cursor)}
      else
        pending_posts =
          [post | socket.assigns.pending_posts]
          |> Enum.uniq_by(& &1.id)
          |> Enum.take(50)

        {:noreply, assign(socket, pending_posts: pending_posts)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <AppShell.app_shell
        id="timeline-shell"
        nav_id="timeline-sidebar"
        main_id="timeline-feed"
        active={:timeline}
        current_user={@current_user}
        notifications_count={@notifications_count}
      >
        <:nav_top>
          <section
            id="compose-panel"
            data-role="compose-panel"
            data-state={if @compose_open?, do: "open", else: "closed"}
            class={[
              "rounded-3xl border border-white/80 bg-white/80 p-6 shadow-xl shadow-slate-200/40 backdrop-blur dark:border-slate-700/60 dark:bg-slate-900/70 dark:shadow-slate-900/40",
              "fixed inset-x-4 bottom-24 z-50 max-h-[78vh] overflow-y-auto lg:static lg:inset-auto lg:bottom-auto lg:z-auto lg:max-h-none lg:overflow-visible",
              !@compose_open? && "hidden lg:block"
            ]}
          >
            <div
              id="compose-mobile-header"
              data-role="compose-mobile-header"
              data-state={if @compose_open?, do: "open", else: "closed"}
              class={[
                "mb-4 flex items-center justify-between lg:hidden",
                !@compose_open? && "hidden"
              ]}
            >
              <p class="text-xs font-semibold uppercase tracking-[0.3em] text-slate-500 dark:text-slate-400">
                Compose
              </p>
              <button
                type="button"
                data-role="compose-close"
                phx-click={close_compose_js() |> JS.push("close_compose")}
                class="inline-flex h-9 w-9 items-center justify-center rounded-2xl text-slate-500 transition hover:bg-slate-900/5 hover:text-slate-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-400 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-white"
                aria-label="Close composer"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div class="flex items-center justify-between">
              <div>
                <p class="text-xs uppercase tracking-[0.3em] text-slate-500 dark:text-slate-400">
                  Compose
                </p>
                <h2 class="mt-2 font-display text-xl text-slate-900 dark:text-slate-100">
                  New post
                </h2>
              </div>
              <div class="hidden text-right text-xs text-slate-500 dark:text-slate-400 sm:block">
                Live updates
              </div>
            </div>

            <%= if @current_user do %>
              <Composer.composer_form
                id="timeline-form"
                id_prefix="compose"
                form={@form}
                upload={@uploads.media}
                media_alt={@media_alt}
                error={@error}
                max_chars={5000}
                param_prefix="post"
                change_event="compose_change"
                submit_event="create_post"
                cancel_event="cancel_media"
                toggle_cw_event="toggle_compose_cw"
                options_open?={@compose_options_open?}
                cw_open?={@compose_cw_open?}
                submit_label="Post"
              />
            <% else %>
              <div class="mt-6 rounded-2xl border border-slate-200/80 bg-white/70 p-4 text-sm text-slate-600 dark:border-slate-700/70 dark:bg-slate-950/50 dark:text-slate-300">
                <p>Posting requires a local account.</p>
                <div class="mt-4 flex flex-wrap items-center gap-2">
                  <.button navigate={~p"/login"} size="sm">Login</.button>
                  <.button navigate={~p"/register"} variant="secondary" size="sm">Register</.button>
                </div>
              </div>
            <% end %>
          </section>
        </:nav_top>

        <section class="space-y-4">
          <div
            id="timeline-top-sentinel"
            phx-hook="TimelineTopSentinel"
            class="h-px w-px"
            aria-hidden="true"
          >
          </div>

          <div class="flex flex-col gap-3 rounded-3xl border border-white/80 bg-white/80 p-5 shadow-lg shadow-slate-200/20 backdrop-blur dark:border-slate-700/60 dark:bg-slate-900/70 dark:shadow-slate-900/40 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="font-display text-xl text-slate-900 dark:text-slate-100">Timeline</h2>
              <p class="mt-1 text-xs uppercase tracking-[0.3em] text-slate-500 dark:text-slate-400">
                {if @timeline == :home, do: "Home", else: "Public"}
              </p>
              <span data-role="timeline-current" class="sr-only">{@timeline}</span>
            </div>

            <div class="flex items-center gap-2">
              <%= if @current_user do %>
                <.link
                  patch={~p"/?timeline=home"}
                  class={[
                    "rounded-full px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] transition",
                    @timeline == :home &&
                      "bg-slate-900 text-white shadow-lg shadow-slate-900/20 hover:bg-slate-800 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-white",
                    @timeline != :home &&
                      "border border-slate-200/80 bg-white/70 text-slate-700 hover:-translate-y-0.5 hover:bg-white dark:border-slate-700/80 dark:bg-slate-950/60 dark:text-slate-200 dark:hover:bg-slate-950"
                  ]}
                >
                  Home
                </.link>
              <% else %>
                <span class="rounded-full border border-slate-200/60 bg-white/40 px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-slate-400 dark:border-slate-700/60 dark:bg-slate-950/40 dark:text-slate-500">
                  Home
                </span>
              <% end %>

              <.link
                patch={~p"/?timeline=public"}
                class={[
                  "rounded-full px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] transition",
                  @timeline == :public &&
                    "bg-slate-900 text-white shadow-lg shadow-slate-900/20 hover:bg-slate-800 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-white",
                  @timeline != :public &&
                    "border border-slate-200/80 bg-white/70 text-slate-700 hover:-translate-y-0.5 hover:bg-white dark:border-slate-700/80 dark:bg-slate-950/60 dark:text-slate-200 dark:hover:bg-slate-950"
                ]}
              >
                Public
              </.link>
            </div>
          </div>

          <% pending_count = length(@pending_posts) %>

          <button
            :if={pending_count > 0 and !@timeline_at_top?}
            type="button"
            data-role="new-posts"
            phx-click={JS.dispatch("predux:scroll-top")}
            class="sticky top-4 z-30 inline-flex w-full items-center justify-center gap-2 rounded-full border border-slate-200/80 bg-white/90 px-6 py-3 text-sm font-semibold text-slate-700 shadow-lg shadow-slate-900/10 backdrop-blur transition hover:-translate-y-0.5 hover:bg-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-400 dark:border-slate-700/80 dark:bg-slate-950/70 dark:text-slate-200 dark:shadow-slate-900/40 dark:hover:bg-slate-950"
            aria-label="Scroll to new posts"
          >
            <.icon name="hero-arrow-up" class="size-4" />
            {new_posts_label(pending_count)}
          </button>

          <div id="timeline-posts" phx-update="stream" class="space-y-4">
            <div
              id="timeline-posts-empty"
              class="hidden only:block rounded-3xl border border-slate-200/80 bg-white/70 p-6 text-sm text-slate-600 shadow-sm shadow-slate-200/20 dark:border-slate-700/70 dark:bg-slate-950/50 dark:text-slate-300 dark:shadow-slate-900/30"
            >
              No posts yet.
            </div>

            <StatusCard.status_card
              :for={{id, entry} <- @streams.posts}
              id={id}
              entry={entry}
              current_user={@current_user}
            />
          </div>

          <div :if={!@posts_end?} class="flex justify-center py-2">
            <.button
              data-role="load-more"
              phx-click="load_more"
              phx-disable-with="Loading..."
              aria-label="Load more posts"
              variant="secondary"
            >
              <.icon name="hero-chevron-down" class="size-4" /> Load more
            </.button>
          </div>

          <div
            :if={!@posts_end?}
            id="timeline-bottom-sentinel"
            phx-hook="TimelineBottomSentinel"
            class="h-px w-full"
            aria-hidden="true"
          >
          </div>
        </section>

        <div
          id="compose-overlay"
          data-role="compose-overlay"
          data-state={if @compose_open?, do: "open", else: "closed"}
          class={[
            "fixed inset-0 z-40 bg-slate-950/50 backdrop-blur-sm lg:hidden",
            !@compose_open? && "hidden"
          ]}
          phx-click={close_compose_js() |> JS.push("close_compose")}
          aria-hidden={!@compose_open?}
        >
        </div>

        <button
          :if={@current_user}
          type="button"
          id="compose-open-button"
          data-role="compose-open"
          data-state={if @compose_open?, do: "hidden", else: "visible"}
          phx-click={open_compose_js() |> JS.push("open_compose")}
          class={[
            "fixed bottom-24 right-6 z-40 inline-flex h-14 w-14 items-center justify-center rounded-full bg-slate-900 text-white shadow-xl shadow-slate-900/30 transition hover:-translate-y-0.5 hover:bg-slate-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-400 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-white lg:hidden",
            @compose_open? && "hidden"
          ]}
          aria-label="Compose a new post"
        >
          <.icon name="hero-pencil-square" class="size-6" />
        </button>
      </AppShell.app_shell>

      <MediaViewer.media_viewer
        viewer={%{items: [], index: 0}}
        open={false}
      />
    </Layouts.app>
    """
  end

  defp timeline_from_params(%{"timeline" => "public"}, _user), do: :public
  defp timeline_from_params(%{"timeline" => "home"}, %User{}), do: :home
  defp timeline_from_params(_params, %User{}), do: :home
  defp timeline_from_params(_params, _user), do: :public

  defp open_compose_js(js \\ %JS{}) do
    js
    |> JS.remove_class("hidden", to: "#compose-panel")
    |> JS.remove_class("hidden", to: "#compose-overlay")
    |> JS.remove_class("hidden", to: "#compose-mobile-header")
    |> JS.add_class("hidden", to: "#compose-open-button")
  end

  defp close_compose_js(js \\ %JS{}) do
    js
    |> JS.add_class("hidden lg:block", to: "#compose-panel")
    |> JS.add_class("hidden", to: "#compose-overlay")
    |> JS.add_class("hidden", to: "#compose-mobile-header")
    |> JS.remove_class("hidden", to: "#compose-open-button")
  end

  defp toggle_compose_options_js(js \\ %JS{}) do
    js
    |> JS.toggle_class("hidden", to: "#compose-options")
    |> JS.toggle_attribute({"value", "true", "false"}, to: "#compose-options-state")
  end

  defp toggle_compose_cw_js(js \\ %JS{}) do
    JS.toggle_class(js, "hidden", to: "#compose-cw")
  end

  defp list_timeline_posts(:home, %User{} = user, opts) when is_list(opts) do
    Objects.list_home_notes(user.ap_id, opts)
  end

  defp list_timeline_posts(_timeline, _user, opts) when is_list(opts) do
    Objects.list_notes(opts)
  end

  defp posts_cursor([]), do: nil

  defp posts_cursor(posts) when is_list(posts) do
    case List.last(posts) do
      %{id: id} when is_integer(id) -> id
      _ -> nil
    end
  end

  defp post_dom_id(%{object: %{id: id}}) when is_integer(id), do: "post-#{id}"
  defp post_dom_id(_post), do: Ecto.UUID.generate()

  defp include_post?(%{type: "Note"} = post, :home, home_actor_ids)
       when is_list(home_actor_ids) do
    is_binary(post.actor) and post.actor in home_actor_ids
  end

  defp include_post?(%{type: "Note"}, _timeline, _home_actor_ids), do: true
  defp include_post?(_post, _timeline, _home_actor_ids), do: false

  defp home_actor_ids(nil), do: []

  defp home_actor_ids(%User{} = user) do
    followed_actor_ids =
      user.ap_id
      |> Relationships.list_follows_by_actor()
      |> Enum.map(& &1.object)
      |> Enum.filter(&is_binary/1)

    Enum.uniq([user.ap_id | followed_actor_ids])
  end

  defp default_post_params do
    %{
      "content" => "",
      "spoiler_text" => "",
      "visibility" => "public",
      "sensitive" => "false",
      "language" => "",
      "ui_options_open" => "false",
      "media_alt" => %{}
    }
  end

  defp remaining_chars(%Phoenix.HTML.Form{} = form) do
    @compose_max_chars - String.length(content_value(form))
  end

  defp remaining_chars(_form), do: @compose_max_chars

  defp compose_max_chars, do: @compose_max_chars

  defp compose_submit_disabled?(form, upload) do
    over_limit = remaining_chars(form) < 0
    content_blank = String.trim(content_value(form)) == ""
    entries = upload_entries(upload)
    no_attachments = entries == []
    attachments_pending = Enum.any?(entries, &(!&1.done?))

    over_limit or (content_blank and no_attachments) or attachments_pending
  end

  defp content_value(%Phoenix.HTML.Form{} = form) do
    (form.params || %{})
    |> Map.get("content", "")
    |> to_string()
  end

  defp content_value(_form), do: ""

  defp upload_entries(%Phoenix.LiveView.UploadConfig{} = upload), do: upload.entries
  defp upload_entries(_upload), do: []

  defp visibility_label(visibility) when is_binary(visibility) do
    case String.trim(visibility) do
      "public" -> "Public"
      "unlisted" -> "Unlisted"
      "private" -> "Private"
      "direct" -> "Direct"
      _ -> "Public"
    end
  end

  defp visibility_label(_visibility), do: "Public"

  defp language_label(language) when is_binary(language) do
    language = String.trim(language)
    if language == "", do: "Auto", else: language
  end

  defp language_label(_language), do: "Auto"

  defp upload_error_text(:too_large), do: "File is too large."
  defp upload_error_text(:not_accepted), do: "Unsupported file type."
  defp upload_error_text(:too_many_files), do: "Too many files selected."
  defp upload_error_text(_), do: "Upload failed."

  defp notifications_count(nil), do: 0

  defp notifications_count(%User{} = user) do
    user
    |> Notifications.list_for_user(limit: 20)
    |> length()
  end

  defp truthy?(value) do
    case value do
      true -> true
      1 -> true
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  defp maybe_flush_pending_posts(socket, true) do
    pending_posts = socket.assigns.pending_posts

    if pending_posts == [] do
      assign(socket, pending_posts: [])
    else
      current_user = socket.assigns.current_user

      {socket, cursor} =
        Enum.reduce(Enum.reverse(pending_posts), {socket, socket.assigns.posts_cursor}, fn post,
                                                                                           {socket,
                                                                                            cursor} ->
          socket = stream_insert(socket, :posts, StatusVM.decorate(post, current_user), at: 0)

          cursor =
            case cursor do
              nil -> post.id
              existing -> min(existing, post.id)
            end

          {socket, cursor}
        end)

      socket
      |> assign(pending_posts: [], posts_cursor: cursor)
    end
  end

  defp maybe_flush_pending_posts(socket, _at_top?), do: socket

  defp new_posts_label(count) when is_integer(count) and count == 1, do: "1 new post"
  defp new_posts_label(count) when is_integer(count) and count > 1, do: "#{count} new posts"
  defp new_posts_label(_count), do: "New posts"

  defp refresh_post(socket, post_id) when is_integer(post_id) do
    current_user = socket.assigns.current_user

    case Objects.get(post_id) do
      %{type: "Note"} = object ->
        stream_insert(socket, :posts, StatusVM.decorate(object, current_user))

      _ ->
        socket
    end
  end
end
