const REACTION_EMOJIS = ["😀", "😂", "😍", "😮", "😢", "😡", "🔥", "👍", "❤️", "🎉", "🙏", "🤔", "🥳", "😎", "💯", "✨"]

const buildOptionButton = emoji => {
  const button = document.createElement("button")
  button.type = "button"
  button.dataset.role = "reaction-picker-option"
  button.dataset.emoji = emoji
  button.className =
    "inline-flex h-9 w-9 items-center justify-center text-xl transition hover:bg-[color:var(--bg-subtle)] focus-visible:outline-none focus-brutal"
  button.textContent = emoji
  button.setAttribute("aria-label", `React with ${emoji}`)
  return button
}

const ReactionPicker = {
  mounted() {
    this.menu = this.findMenu()
    this.toggleButton = this.findToggle()
    this.grid = this.findGrid()

    this.onClick = e => {
      const option = e.target?.closest?.("[data-role='reaction-picker-option']")
      if (option && this.el.contains(option)) {
        e.preventDefault()
        this.dispatchOptimisticToggle(option)
        this.pushReaction(option.dataset.emoji || option.textContent || "")
        this.setOpen(false)
        return
      }

      const toggle = e.target?.closest?.("[data-role='reaction-picker-toggle']")
      if (toggle && this.el.contains(toggle)) {
        e.preventDefault()
        const nextOpen = !this.isOpen()
        if (nextOpen) this.ensureOptions()
        this.setOpen(nextOpen)
      }
    }

    this.onDocumentClick = e => {
      if (!this.isOpen()) return
      if (e.target && this.el.contains(e.target)) return
      this.setOpen(false)
    }

    this.onKeydown = e => {
      if (!this.isOpen()) return
      if (e.key === "Escape" || e.key === "Esc") {
        this.setOpen(false)
        this.toggleButton?.focus?.({preventScroll: true})
      }
    }

    this.el.addEventListener("click", this.onClick)
    document.addEventListener("click", this.onDocumentClick)
    window.addEventListener("keydown", this.onKeydown)

    this.setOpen(false)
  },

  updated() {
    this.menu = this.findMenu()
    this.toggleButton = this.findToggle()
    this.grid = this.findGrid()
    this.syncAria()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    document.removeEventListener("click", this.onDocumentClick)
    window.removeEventListener("keydown", this.onKeydown)
  },

  findMenu() {
    return this.el.querySelector("[data-role='reaction-picker-menu']")
  },

  findToggle() {
    return this.el.querySelector("[data-role='reaction-picker-toggle']")
  },

  findGrid() {
    return this.el.querySelector("[data-role='reaction-picker-grid']")
  },

  isOpen() {
    if (!this.menu) return false
    return !this.menu.classList.contains("hidden") && this.menu.dataset.state === "open"
  },

  setOpen(open) {
    if (!this.menu) return

    const isOpen = !!open
    this.menu.dataset.state = isOpen ? "open" : "closed"
    this.menu.classList.toggle("hidden", !isOpen)
    this.menu.setAttribute("aria-hidden", isOpen ? "false" : "true")

    if (this.toggleButton) {
      this.toggleButton.setAttribute("aria-expanded", isOpen ? "true" : "false")
    }
  },

  syncAria() {
    if (!this.menu || !this.toggleButton) return
    const isOpen = this.isOpen()
    this.menu.setAttribute("aria-hidden", isOpen ? "false" : "true")
    this.toggleButton.setAttribute("aria-expanded", isOpen ? "true" : "false")
  },

  ensureOptions() {
    if (!this.grid) return
    if (this.grid.childElementCount > 0) return

    const fragment = document.createDocumentFragment()
    for (const emoji of REACTION_EMOJIS) fragment.appendChild(buildOptionButton(emoji))
    this.grid.appendChild(fragment)
  },

  pushReaction(emoji) {
    const value = String(emoji || "").trim()
    if (!value) return

    const postId = this.el.dataset.postId
    if (!postId) return

    const payload = {id: postId, emoji: value}
    const feedId = this.el.dataset.feedId
    if (feedId) payload.feed_id = feedId

    this.pushEvent("toggle_reaction", payload)
  },

  dispatchOptimisticToggle(target) {
    if (!(target instanceof HTMLElement)) return

    target.dispatchEvent(
      new CustomEvent("egregoros:optimistic-toggle", {
        bubbles: true,
        detail: {kind: "reaction"},
      })
    )
  },
}

export default ReactionPicker

