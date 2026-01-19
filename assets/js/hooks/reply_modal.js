import {lockScroll, unlockScroll} from "./scroll_lock"

const ReplyModal = {
  mounted() {
    this.lastFocused = null

    this.onOpen = e => {
      this.lastFocused = document.activeElement

      const detail = e?.detail || {}
      const inReplyTo = detail.in_reply_to || detail.inReplyTo || ""
      const actorHandle = detail.actor_handle || detail.actorHandle || ""
      this.setReplyTarget({inReplyTo, actorHandle})

      this.open()
      this.focusTextarea()
    }

    this.onClose = () => {
      this.close()
    }

    this.el.addEventListener("egregoros:reply-open", this.onOpen)
    this.el.addEventListener("egregoros:reply-close", this.onClose)

    this.onKeydown = e => {
      if (!this.el.isConnected) return
      if (e.defaultPrevented) return
      if (!this.isOpen()) return

      if (e.key === "Escape" || e.key === "Esc") {
        this.close()
        this.pushEvent("close_reply_modal", {})
        e.preventDefault()
      }
    }

    window.addEventListener("keydown", this.onKeydown)

    this.handleEvent("reply_modal_prefill", payload => {
      if (!this.el.isConnected) return

      const detail = payload || {}
      const content = String(detail.content || "")
      if (!content) return

      const expectedInReplyTo = detail.in_reply_to || detail.inReplyTo

      if (expectedInReplyTo) {
        const input = this.el.querySelector("input[data-role='reply-in-reply-to']")
        if (input && String(input.value || "") !== String(expectedInReplyTo)) return
      }

      const textarea = this.el.querySelector("textarea[data-role='compose-content']")
      if (!textarea) return

      const current = String(textarea.value || "")

      if (current.trim() === "") {
        textarea.value = content
      } else if (!current.startsWith(content)) {
        textarea.value = `${content}${current}`
      } else {
        return
      }

      textarea.dispatchEvent(new Event("input", {bubbles: true}))

      try {
        textarea.setSelectionRange(textarea.value.length, textarea.value.length)
      } catch (_e) {}
    })

    this.handleEvent("reply_modal_close", () => this.close())
  },

  destroyed() {
    if (this.isOpen()) unlockScroll()
    this.el.removeEventListener("egregoros:reply-open", this.onOpen)
    this.el.removeEventListener("egregoros:reply-close", this.onClose)
    window.removeEventListener("keydown", this.onKeydown)
  },

  isOpen() {
    return this.el.dataset.state === "open" && !this.el.classList.contains("hidden")
  },

  open() {
    lockScroll()
    this.el.classList.remove("hidden")
    this.el.dataset.state = "open"
    this.el.setAttribute("aria-hidden", "false")
  },

  close() {
    unlockScroll()
    this.el.classList.add("hidden")
    this.el.dataset.state = "closed"
    this.el.setAttribute("aria-hidden", "true")
    this.clearReplyTarget()
    this.clearTextarea()
    this.restoreFocus()
  },

  setReplyTarget({inReplyTo, actorHandle}) {
    const input = this.el.querySelector("input[data-role='reply-in-reply-to']")
    if (input) input.value = String(inReplyTo || "")

    const wrapper = this.el.querySelector("[data-role='reply-modal-target']")
    const handleEl = this.el.querySelector("[data-role='reply-modal-target-handle']")
    if (!wrapper || !handleEl) return

    const handle = String(actorHandle || "").trim()

    if (handle) {
      handleEl.textContent = handle
      wrapper.classList.remove("hidden")
    } else {
      handleEl.textContent = ""
      wrapper.classList.add("hidden")
    }
  },

  clearReplyTarget() {
    const input = this.el.querySelector("input[data-role='reply-in-reply-to']")
    if (input) input.value = ""

    const wrapper = this.el.querySelector("[data-role='reply-modal-target']")
    const handleEl = this.el.querySelector("[data-role='reply-modal-target-handle']")
    if (!wrapper || !handleEl) return

    handleEl.textContent = ""
    wrapper.classList.add("hidden")
  },

  restoreFocus() {
    if (!this.lastFocused) return
    const target = this.lastFocused
    this.lastFocused = null
    if (target.isConnected && typeof target.focus === "function") target.focus({preventScroll: true})
  },

  focusTextarea() {
    const textarea = this.el.querySelector("textarea[data-role='compose-content']")
    if (textarea) textarea.focus({preventScroll: true})
  },

  clearTextarea() {
    const textarea = this.el.querySelector("textarea[data-role='compose-content']")
    if (!textarea) return
    if (textarea.value === "") return

    textarea.value = ""
    textarea.dispatchEvent(new Event("input", {bubbles: true}))
  },
}

export default ReplyModal
