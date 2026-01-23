import {lockScroll, unlockScroll} from "./scroll_lock"

const shouldLockScroll = () => window.matchMedia?.("(max-width: 1023px)")?.matches

const ComposePanel = {
  mounted() {
    this.uiOpen = false

    this.onOpen = () => this.open()
    this.onClose = () => this.close()

    this.el.addEventListener("egregoros:compose-open", this.onOpen)
    this.el.addEventListener("egregoros:compose-close", this.onClose)

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
    this.handleEvent("compose_panel_close", () => this.close())
    this.applyVisibility()
  },

  updated() {
    if (!this.el.isConnected) return
    this.applyVisibility()
  },

  destroyed() {
    if (this.uiOpen && shouldLockScroll()) unlockScroll()
    this.el.removeEventListener("egregoros:compose-open", this.onOpen)
    this.el.removeEventListener("egregoros:compose-close", this.onClose)
    window.removeEventListener("keydown", this.onKeydown)
  },

  isOpen() {
    return this.uiOpen
  },

  open() {
    this.uiOpen = true
    this.applyVisibility()
    this.focusTextarea()
  },

  close() {
    this.uiOpen = false
    this.applyVisibility()
  },

  applyVisibility() {
    const overlay = document.querySelector("#compose-overlay")
    const header = document.querySelector("#compose-mobile-header")
    const openButton = document.querySelector("#compose-open-button")

    if (this.uiOpen) {
      if (shouldLockScroll()) lockScroll()
      this.el.classList.remove("hidden")
      this.el.dataset.state = "open"
      this.el.setAttribute("aria-hidden", "false")

      if (overlay) {
        overlay.classList.remove("hidden")
        overlay.dataset.state = "open"
        overlay.setAttribute("aria-hidden", "false")
      }

      if (header) {
        header.classList.remove("hidden")
        header.dataset.state = "open"
      }

      if (openButton) {
        openButton.classList.add("hidden")
        openButton.dataset.state = "hidden"
        openButton.setAttribute("aria-hidden", "true")
      }
    } else {
      if (shouldLockScroll()) unlockScroll()
      this.el.classList.add("hidden")
      this.el.dataset.state = "closed"
      this.el.setAttribute("aria-hidden", "true")

      if (overlay) {
        overlay.classList.add("hidden")
        overlay.dataset.state = "closed"
        overlay.setAttribute("aria-hidden", "true")
      }

      if (header) {
        header.classList.add("hidden")
        header.dataset.state = "closed"
      }

      if (openButton) {
        openButton.classList.remove("hidden")
        openButton.dataset.state = "visible"
        openButton.setAttribute("aria-hidden", "false")
      }
    }
  },

  focusTextarea() {
    const textarea = this.el.querySelector("textarea[data-role='compose-content']")
    if (textarea) textarea.focus({preventScroll: true})
  },
}

export default ComposePanel

