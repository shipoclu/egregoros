const EmojiPicker = {
  mounted() {
    this.menu = this.findMenu()
    this.toggleButton = this.findToggle()

    this.onClick = e => {
      const option = e.target?.closest?.("[data-role='compose-emoji-option']")
      if (option && this.el.contains(option)) {
        e.preventDefault()
        this.insertEmoji(option.dataset.emoji || option.textContent || "")
        this.setOpen(false)
        return
      }

      const toggle = e.target?.closest?.("[data-role='compose-emoji']")
      if (toggle && this.el.contains(toggle)) {
        e.preventDefault()
        this.setOpen(!this.isOpen())
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
    this.syncAria()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    document.removeEventListener("click", this.onDocumentClick)
    window.removeEventListener("keydown", this.onKeydown)
  },

  findMenu() {
    return this.el.querySelector("[data-role='compose-emoji-menu']")
  },

  findToggle() {
    return this.el.querySelector("[data-role='compose-emoji']")
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

  insertEmoji(emoji) {
    const value = String(emoji || "")
    if (!value) return

    const textarea = this.findTextarea()
    if (!textarea) return

    const start = textarea.selectionStart ?? textarea.value.length
    const end = textarea.selectionEnd ?? textarea.value.length

    try {
      textarea.setRangeText(value, start, end, "end")
    } catch (_error) {
      textarea.value = `${textarea.value || ""}${value}`
    }

    textarea.dispatchEvent(new Event("input", {bubbles: true}))
    textarea.focus({preventScroll: true})
  },

  findTextarea() {
    const form = this.el.closest("form")
    if (!form) return null
    return form.querySelector("textarea[data-role='compose-content']")
  },
}

export default EmojiPicker
