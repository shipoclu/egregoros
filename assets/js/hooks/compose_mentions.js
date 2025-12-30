const ComposeMentions = {
  mounted() {
    this.scope = this.el.dataset.mentionScope || ""
    this.input = this.findInput()
    this.debounceTimer = null
    this.currentQuery = null
    this.activeMention = null

    if (!this.input) return

    this.onInput = () => this.handleInput()
    this.onCursor = () => this.handleInput()

    this.onMentionSelect = e => {
      const handle = e?.detail?.handle
      if (!handle || !this.input) return

      const mention = this.extractMentionAtCursor() || this.activeMention
      if (!mention) return

      const value = this.input.value || ""
      const before = value.slice(0, mention.start)
      const after = value.slice(mention.end)
      const insertion = `${handle} `

      this.input.value = before + insertion + after
      const newPos = before.length + insertion.length
      this.input.selectionStart = newPos
      this.input.selectionEnd = newPos
      this.input.focus()
      this.input.dispatchEvent(new Event("input", {bubbles: true}))

      this.clearSuggestions()
    }

    this.input.addEventListener("input", this.onInput)
    this.input.addEventListener("keyup", this.onCursor)
    this.input.addEventListener("click", this.onCursor)
    this.el.addEventListener("egregoros:mention-select", this.onMentionSelect)

    this.handleInput()
  },

  isMentionBoundaryChar: ch => {
    if (!ch) return true
    return /\s/.test(ch) || /[\(\[\{\<"'.,!?;:]/.test(ch)
  },

  updated() {
    const nextInput = this.findInput()
    if (nextInput !== this.input) {
      if (this.input) {
        this.input.removeEventListener("input", this.onInput)
        this.input.removeEventListener("keyup", this.onCursor)
        this.input.removeEventListener("click", this.onCursor)
      }

      this.input = nextInput
      if (this.input) {
        this.input.addEventListener("input", this.onInput)
        this.input.addEventListener("keyup", this.onCursor)
        this.input.addEventListener("click", this.onCursor)
      }
    }
  },

  destroyed() {
    clearTimeout(this.debounceTimer)

    if (this.input) {
      this.input.removeEventListener("input", this.onInput)
      this.input.removeEventListener("keyup", this.onCursor)
      this.input.removeEventListener("click", this.onCursor)
    }

    this.el.removeEventListener("egregoros:mention-select", this.onMentionSelect)
  },

  findInput() {
    return this.el.querySelector("textarea[data-role='compose-content']")
  },

  handleInput() {
    if (!this.input) return

    const mention = this.extractMentionAtCursor()

    if (!mention) {
      this.clearSuggestions()
      return
    }

    if (mention.query === this.currentQuery) {
      this.activeMention = mention
      return
    }

    this.activeMention = mention
    this.currentQuery = mention.query
    this.requestSearch(mention.query)
  },

  requestSearch(query) {
    clearTimeout(this.debounceTimer)

    this.debounceTimer = setTimeout(() => {
      if (!this.scope) return
      this.pushEvent("mention_search", {q: query, scope: this.scope})
    }, 120)
  },

  clearSuggestions() {
    if (!this.scope) return
    if (this.currentQuery === null) return

    this.currentQuery = null
    this.activeMention = null
    clearTimeout(this.debounceTimer)
    this.pushEvent("mention_clear", {scope: this.scope})
  },

  extractMentionAtCursor() {
    if (!this.input) return null

    const value = this.input.value || ""
    const pos = typeof this.input.selectionStart === "number" ? this.input.selectionStart : value.length

    if (!pos) return null

    let i = pos - 1
    while (i >= 0) {
      const ch = value[i]
      if (ch === "@") break
      if (/\s/.test(ch)) return null
      i -= 1
    }

    if (i < 0) return null
    if (i > 0 && !this.isMentionBoundaryChar(value[i - 1])) return null

    const raw = value.slice(i + 1, pos)
    if (!raw) return null

    if (!/^[A-Za-z0-9_.-]{1,64}(@[A-Za-z0-9.:-]{0,255})?$/.test(raw)) return null

    return {start: i, end: pos, query: raw}
  },
}

export default ComposeMentions
