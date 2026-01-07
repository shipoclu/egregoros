const ComposeSettings = {
  mounted() {
    this.visibilityLabel = null
    this.languageLabel = null

    this.updateMenuPlacement = (toggleButton, menuSelector) => {
      if (!toggleButton) return

      requestAnimationFrame(() => {
        const menu = toggleButton.parentElement?.querySelector?.(menuSelector)
        if (!menu) return
        if (menu.classList.contains("hidden") || menu.dataset.state !== "open") return

        const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0
        const toggleRect = toggleButton.getBoundingClientRect()
        const menuRect = menu.getBoundingClientRect()

        const spaceBelow = viewportHeight - toggleRect.bottom
        const spaceAbove = toggleRect.top
        const shouldFlip = menuRect.height > spaceBelow && spaceAbove > spaceBelow

        menu.dataset.placement = shouldFlip ? "top" : "bottom"
      })
    }

    this.onChange = e => {
      const target = e?.target
      if (!(target instanceof HTMLElement)) return
      if (target.matches("input[type='radio'][name$='[visibility]']")) this.updateVisibilityLabel()
    }

    this.onInput = e => {
      const target = e?.target
      if (!(target instanceof HTMLElement)) return
      if (target.matches("input[name$='[language]']")) this.updateLanguageLabel()
    }

    this.onClick = e => {
      const target = e?.target
      if (!(target instanceof HTMLElement)) return

      const visibilityToggle = target.closest?.("[data-role='compose-visibility-pill']")
      if (visibilityToggle && this.el.contains(visibilityToggle)) {
        this.updateMenuPlacement(visibilityToggle, "[data-role='compose-visibility-menu']")
      }

      const languageToggle = target.closest?.("[data-role='compose-language-pill']")
      if (languageToggle && this.el.contains(languageToggle)) {
        this.updateMenuPlacement(languageToggle, "[data-role='compose-language-menu']")
      }
    }

    this.el.addEventListener("change", this.onChange)
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("click", this.onClick)
    this.updateVisibilityLabel()
    this.updateLanguageLabel()
  },

  updated() {
    this.updateVisibilityLabel()
    this.updateLanguageLabel()
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("click", this.onClick)
  },

  updateVisibilityLabel() {
    if (!this.visibilityLabel || !this.visibilityLabel.isConnected) {
      this.visibilityLabel = this.el.querySelector("[data-role='compose-visibility-label']")
    }

    if (!this.visibilityLabel) return

    const selected =
      this.el.querySelector("input[type='radio'][name$='[visibility]']:checked")?.value || "public"

    const normalized = String(selected).trim()
    const text = this.visibilityText(normalized)

    if (this.visibilityLabel.textContent !== text) this.visibilityLabel.textContent = text
  },

  updateLanguageLabel() {
    if (!this.languageLabel || !this.languageLabel.isConnected) {
      this.languageLabel = this.el.querySelector("[data-role='compose-language-label']")
    }

    if (!this.languageLabel) return

    const raw = this.el.querySelector("input[name$='[language]']")?.value || ""
    const normalized = String(raw).trim()
    const text = this.languageText(normalized)

    if (this.languageLabel.textContent !== text) this.languageLabel.textContent = text
  },

  visibilityText: value => {
    switch (value) {
      case "public":
        return "Public"
      case "unlisted":
        return "Unlisted"
      case "private":
        return "Followers"
      case "direct":
        return "Direct"
      default:
        return "Public"
    }
  },

  languageText: value => {
    if (!value || value === "auto") return "Auto"
    return value
  },
}

export default ComposeSettings
