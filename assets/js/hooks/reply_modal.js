import {lockScroll, unlockScroll} from "./scroll_lock"

const normalizeHandle = handle => {
  let value = String(handle || "").trim()
  if (!value) return ""
  if (!value.startsWith("@")) value = `@${value}`
  return value
}

const coerceHandleList = value => {
  if (!value) return []

  if (Array.isArray(value)) {
    return value.map(normalizeHandle).filter(Boolean)
  }

  if (typeof value === "string") {
    return value
      .split(/\s+/)
      .map(normalizeHandle)
      .filter(Boolean)
  }

  return []
}

const buildPrefill = ({actorHandle, mentionHandles, currentUserHandle}) => {
  const current = normalizeHandle(currentUserHandle)
  const handles = [normalizeHandle(actorHandle), ...coerceHandleList(mentionHandles)]
    .filter(Boolean)
    .filter(handle => handle !== current)

  const unique = [...new Set(handles)]
  if (unique.length === 0) return ""

  return `${unique.join(" ")} `
}

const ReplyModal = {
  mounted() {
    this.lastFocused = null
    this.lastInReplyTo = ""
    this.uiOpen = false
    this.target = {inReplyTo: "", actorHandle: "", mentionHandles: []}

    this.onOpen = e => {
      this.lastFocused = document.activeElement

      const detail = e?.detail || {}
      const inReplyTo = detail.in_reply_to || detail.inReplyTo || ""
      const actorHandle = detail.actor_handle || detail.actorHandle || ""
      const mentionHandles = detail.mention_handles || detail.mentionHandles || []

      this.target = {inReplyTo, actorHandle, mentionHandles}

      if (String(inReplyTo || "") !== String(this.lastInReplyTo || "")) this.clearTextarea()
      this.setReplyTarget({inReplyTo, actorHandle})

      this.open()
      this.applyPrefill({inReplyTo, actorHandle, mentionHandles})
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
        e.preventDefault()
      }
    }

    window.addEventListener("keydown", this.onKeydown)
    this.handleEvent("reply_modal_close", () => this.close())

    const url = new URL(window.location.href)

    if (this.truthyParam(url.searchParams.get("reply"))) {
      const inReplyTo = this.el.dataset.prefillInReplyTo || ""
      const actorHandle = this.el.dataset.prefillActorHandle || ""
      const mentionHandles = this.el.dataset.prefillMentionHandles || ""

      this.target = {inReplyTo, actorHandle, mentionHandles}
      this.setReplyTarget({inReplyTo, actorHandle})
      this.open()
      this.applyPrefill({inReplyTo, actorHandle, mentionHandles})
      this.focusTextarea()
    }
  },

  updated() {
    if (!this.el.isConnected) return
    this.applyVisibility()

    if (this.uiOpen) {
      this.setReplyTarget({inReplyTo: this.target.inReplyTo, actorHandle: this.target.actorHandle})
    }
  },

  destroyed() {
    if (this.uiOpen) unlockScroll()
    this.el.removeEventListener("egregoros:reply-open", this.onOpen)
    this.el.removeEventListener("egregoros:reply-close", this.onClose)
    window.removeEventListener("keydown", this.onKeydown)
  },

  isOpen() {
    return this.uiOpen
  },

  open() {
    this.uiOpen = true
    this.applyVisibility()
  },

  applyVisibility() {
    if (this.uiOpen) {
      lockScroll()
      this.el.classList.remove("hidden")
      this.el.dataset.state = "open"
      this.el.setAttribute("aria-hidden", "false")
    } else {
      unlockScroll()
      this.el.classList.add("hidden")
      this.el.dataset.state = "closed"
      this.el.setAttribute("aria-hidden", "true")
    }
  },

  close() {
    if (!this.uiOpen) {
      this.applyVisibility()
      return
    }
    this.uiOpen = false
    this.applyVisibility()

    this.lastInReplyTo = ""
    this.target = {inReplyTo: "", actorHandle: "", mentionHandles: []}
    this.clearReplyTarget()
    this.clearTextarea()
    this.clearReplyUrlFlag()
    this.restoreFocus()
  },

  truthyParam(value) {
    const normalized = String(value || "").trim().toLowerCase()
    return normalized === "true" || normalized === "1" || normalized === "yes" || normalized === "on"
  },

  clearReplyUrlFlag() {
    try {
      const url = new URL(window.location.href)
      if (!this.truthyParam(url.searchParams.get("reply"))) return

      url.searchParams.delete("reply")
      if (url.hash === "#reply-form") url.hash = ""

      window.history.replaceState({}, "", url)
    } catch (_e) {}
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

  applyPrefill({inReplyTo, actorHandle, mentionHandles}) {
    this.lastInReplyTo = String(inReplyTo || "")

    const textarea = this.el.querySelector("textarea[data-role='compose-content']")
    if (!textarea) return
    if (textarea.value.trim() !== "") return

    const prefill = buildPrefill({
      actorHandle,
      mentionHandles,
      currentUserHandle: this.el.dataset.currentUserHandle || "",
    })

    if (!prefill) return

    textarea.value = prefill
    textarea.dispatchEvent(new Event("input", {bubbles: true}))

    try {
      textarea.setSelectionRange(textarea.value.length, textarea.value.length)
    } catch (_e) {}
  },
}

export default ReplyModal
