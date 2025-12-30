const ComposeCharCounter = {
  mounted() {
    this.maxChars = this.readMaxChars()
    this.counter = this.findCounter()
    this.submitButton = this.findSubmitButton()
    this.segmenter = this.buildSegmenter()

    this.onInput = () => this.update()
    this.el.addEventListener("input", this.onInput)
    this.update()
  },

  updated() {
    this.update()
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
  },

  readMaxChars() {
    const raw = this.el.dataset.maxChars
    const parsed = parseInt(raw || "0", 10)
    if (Number.isFinite(parsed) && parsed > 0) return parsed
    return 0
  },

  buildSegmenter() {
    if (!window.Intl || !Intl.Segmenter) return null
    try {
      return new Intl.Segmenter(undefined, {granularity: "grapheme"})
    } catch (_error) {
      return null
    }
  },

  countChars(text) {
    if (!text) return 0

    if (this.segmenter) {
      let count = 0
      for (const _segment of this.segmenter.segment(text)) count++
      return count
    }

    return Array.from(text).length
  },

  findCounter() {
    const form = this.el.closest("form")
    if (!form) return null
    return form.querySelector("[data-role='compose-char-counter']")
  },

  findSubmitButton() {
    const form = this.el.closest("form")
    if (!form) return null
    return form.querySelector("[data-role='compose-submit']")
  },

  update() {
    const form = this.el.closest("form")
    if (!form) return

    if (!this.counter || !this.counter.isConnected) this.counter = this.findCounter()
    if (!this.submitButton || !this.submitButton.isConnected) this.submitButton = this.findSubmitButton()

    const remaining = this.maxChars ? this.maxChars - this.countChars(this.el.value || "") : null

    if (this.counter && this.counter.isConnected && remaining !== null) {
      this.counter.textContent = String(remaining)

      const overLimit = remaining < 0
      this.counter.classList.toggle("text-rose-600", overLimit)
      this.counter.classList.toggle("dark:text-rose-400", overLimit)
      this.counter.classList.toggle("text-slate-500", !overLimit)
      this.counter.classList.toggle("dark:text-slate-400", !overLimit)
    }

    this.updateSubmitDisabled(form, remaining)
  },

  updateSubmitDisabled(form, remaining) {
    if (!this.submitButton || !this.submitButton.isConnected) return

    const contentBlank = !String(this.el.value || "").trim()
    const hasMedia = form.querySelector("[data-role='media-entry'], [data-role='reply-media-entry']") !== null
    const hasUploadError =
      form.querySelector("[data-role='upload-error'], [data-role='reply-upload-error']") !== null

    const uploadPending = Array.from(
      form.querySelectorAll("[data-role='media-progress'], [data-role='reply-media-progress']")
    ).some(node => {
      const pct = parseInt(node.textContent || "0", 10)
      return Number.isFinite(pct) && pct < 100
    })

    const overLimit = remaining !== null && remaining < 0
    const disabled = overLimit || (contentBlank && !hasMedia) || uploadPending || hasUploadError

    this.submitButton.disabled = disabled
  },
}

export default ComposeCharCounter
