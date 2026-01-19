defmodule EgregorosWeb.ReplyModal do
  use EgregorosWeb, :html

  @moduledoc false

  attr :id, :string, default: "reply-modal"
  attr :form_id, :string, default: "reply-modal-form"
  attr :id_prefix, :string, default: "reply-modal"

  attr :form, :any, required: true
  attr :upload, :any, required: true
  attr :media_alt, :map, default: %{}

  attr :reply_to_handle, :string, default: nil
  attr :current_user_handle, :string, default: nil
  attr :prefill_mention_handles, :list, default: []
  attr :prefill_in_reply_to, :string, default: nil

  attr :mention_suggestions, :map, default: %{}

  attr :max_chars, :integer, default: 5000
  attr :options_open?, :boolean, default: false
  attr :cw_open?, :boolean, default: false

  attr :change_event, :string, default: "reply_change"
  attr :submit_event, :string, default: "create_reply"
  attr :cancel_event, :string, default: "cancel_reply_media"
  attr :toggle_cw_event, :string, default: "toggle_reply_cw"

  def reply_modal(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="reply-modal"
      data-state="closed"
      data-current-user-handle={@current_user_handle}
      data-prefill-actor-handle={@reply_to_handle}
      data-prefill-mention-handles={Enum.join(@prefill_mention_handles, " ")}
      data-prefill-in-reply-to={@prefill_in_reply_to}
      role="dialog"
      aria-modal="true"
      aria-hidden="true"
      phx-hook="ReplyModal"
      class="fixed inset-0 z-50 flex hidden items-center justify-center bg-[color:var(--text-primary)]/60 p-4"
    >
      <.focus_wrap
        id={"#{@id}-dialog"}
        phx-click-away={close_js(@id)}
        class="relative w-full max-w-2xl overflow-visible border-2 border-[color:var(--border-default)] bg-[color:var(--bg-base)] p-6"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <p class="text-xs font-bold uppercase tracking-wide text-[color:var(--text-muted)]">
              Reply
            </p>

            <% has_target? = is_binary(@reply_to_handle) and @reply_to_handle != "" %>

            <p
              data-role="reply-modal-target"
              class={[
                "mt-2 truncate text-sm font-bold text-[color:var(--text-primary)]",
                !has_target? && "hidden"
              ]}
            >
              Replying to <span data-role="reply-modal-target-handle">{@reply_to_handle}</span>
            </p>
          </div>

          <.icon_button
            data-role="reply-modal-close"
            phx-click={close_js(@id)}
            label="Close reply composer"
            class="shrink-0"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.icon_button>
        </div>

        <Composer.composer_form
          id={@form_id}
          id_prefix={@id_prefix}
          form={@form}
          upload={@upload}
          media_alt={@media_alt}
          mention_suggestions={Map.get(@mention_suggestions, @id_prefix, [])}
          param_prefix="reply"
          max_chars={@max_chars}
          options_open?={@options_open?}
          cw_open?={@cw_open?}
          change_event={@change_event}
          submit_event={@submit_event}
          cancel_event={@cancel_event}
          toggle_cw_event={@toggle_cw_event}
          submit_label="Reply"
          class="mt-0"
        >
          <:extra_fields>
            <input
              type="text"
              name="reply[in_reply_to]"
              value={
                @prefill_in_reply_to ||
                  Map.get(@form.params || %{}, "in_reply_to", "")
              }
              data-role="reply-in-reply-to"
              class="hidden"
              autocomplete="off"
            />
          </:extra_fields>
        </Composer.composer_form>
      </.focus_wrap>
    </div>
    """
  end

  defp close_js(id) when is_binary(id) do
    JS.dispatch("egregoros:reply-close", to: "##{id}")
  end
end
