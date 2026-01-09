const ComposeMentions = {
  mounted() {
    this.scope = this.el.dataset.mentionScope || ""
    this.input = this.findInput()
    this.debounceTimer = null
    this.currentQuery = null
    this.activeMention = null
    this.selectedIndex = -1
    this.mirror = null

    if (!this.input) return

    this.onInput = () => this.handleInput()
    this.onCursor = () => this.handleInput()

    this.onKeydown = e => {
      const suggestions = this.getSuggestionButtons()
      if (suggestions.length === 0) return

      if (e.key === "ArrowDown") {
        e.preventDefault()
        this.selectedIndex = Math.min(this.selectedIndex + 1, suggestions.length - 1)
        this.updateHighlight(suggestions)
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
        this.updateHighlight(suggestions)
      } else if (e.key === "Enter" && this.selectedIndex >= 0) {
        e.preventDefault()
        const selected = suggestions[this.selectedIndex]
        if (selected) {
          const handle = selected.dataset.handle
          if (handle) this.selectMention(handle)
        }
      } else if (e.key === "Escape") {
        this.clearSuggestions()
      }
    }

    this.onMentionSelect = e => {
      const handle = e?.detail?.handle
      if (!handle || !this.input) return
      this.selectMention(handle)
    }

    this.input.addEventListener("input", this.onInput)
    this.input.addEventListener("keyup", this.onCursor)
    this.input.addEventListener("click", this.onCursor)
    this.input.addEventListener("keydown", this.onKeydown)
    this.el.addEventListener("egregoros:mention-select", this.onMentionSelect)

    this.handleInput()
  },

  selectMention(handle) {
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
  },

  getSuggestionButtons() {
    const container = this.el.querySelector("[data-role='compose-mention-suggestions']")
    if (!container) return []
    return Array.from(container.querySelectorAll("[data-role='mention-suggestion']"))
  },

  updateHighlight(suggestions) {
    suggestions.forEach((btn, i) => {
      if (i === this.selectedIndex) {
        btn.setAttribute("data-selected", "true")
        btn.scrollIntoView({block: "nearest"})
      } else {
        btn.removeAttribute("data-selected")
      }
    })
  },

  createMirror() {
    if (this.mirror) return
    this.mirror = document.createElement("div")
    this.mirror.style.cssText = `
      position: absolute;
      top: -9999px;
      left: -9999px;
      visibility: hidden;
      white-space: pre-wrap;
      word-wrap: break-word;
      overflow: hidden;
      pointer-events: none;
    `
    document.body.appendChild(this.mirror)
  },

  destroyMirror() {
    if (this.mirror && this.mirror.parentNode) {
      this.mirror.parentNode.removeChild(this.mirror)
    }
    this.mirror = null
  },

  getCaretCoordinates() {
    if (!this.input) return null

    this.createMirror()

    const textarea = this.input
    const computed = window.getComputedStyle(textarea)

    // Copy all styles that affect text layout
    const props = [
      "fontFamily", "fontSize", "fontWeight", "fontStyle",
      "letterSpacing", "wordSpacing", "lineHeight", "textTransform",
      "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
      "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
      "boxSizing"
    ]
    props.forEach(p => { this.mirror.style[p] = computed[p] })
    this.mirror.style.width = `${textarea.offsetWidth}px`

    // Build HTML content up to cursor position
    const cursorPos = textarea.selectionStart || 0
    const text = textarea.value.substring(0, cursorPos)

    let html = ""
    for (const ch of text) {
      if (ch === "\n") html += "<br>"
      else if (ch === " ") html += "\u00a0"
      else if (ch === "<") html += "&lt;"
      else if (ch === ">") html += "&gt;"
      else if (ch === "&") html += "&amp;"
      else html += ch
    }

    // Add marker span at cursor position
    this.mirror.innerHTML = html + "<span>|</span>"

    // Position mirror at textarea location for accurate measurement
    const textareaRect = textarea.getBoundingClientRect()
    this.mirror.style.top = `${textareaRect.top + window.scrollY}px`
    this.mirror.style.left = `${textareaRect.left + window.scrollX}px`

    const marker = this.mirror.lastElementChild
    const markerRect = marker.getBoundingClientRect()

    // Move mirror back off-screen
    this.mirror.style.top = "-9999px"
    this.mirror.style.left = "-9999px"

    // Calculate position relative to textarea, accounting for scroll
    return {
      top: markerRect.top - textareaRect.top - textarea.scrollTop,
      left: markerRect.left - textareaRect.left
    }
  },

  positionDropdown() {
    const dropdown = this.el.querySelector("[data-role='compose-mention-suggestions']")
    if (!dropdown) return

    const coords = this.getCaretCoordinates()
    if (!coords) {
      dropdown.style.top = "1.75rem"
      return
    }

    const lineHeight = parseFloat(window.getComputedStyle(this.input).lineHeight) || 24
    // Position dropdown just below the current line
    dropdown.style.top = `${Math.max(0, coords.top + lineHeight + 2)}px`
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
        this.input.removeEventListener("keydown", this.onKeydown)
      }

      this.input = nextInput
      if (this.input) {
        this.input.addEventListener("input", this.onInput)
        this.input.addEventListener("keyup", this.onCursor)
        this.input.addEventListener("click", this.onCursor)
        this.input.addEventListener("keydown", this.onKeydown)
      }
    }

    // Select first suggestion by default when suggestions appear
    const suggestions = this.getSuggestionButtons()
    if (suggestions.length > 0) {
      this.selectedIndex = 0
      this.updateHighlight(suggestions)
    } else {
      this.selectedIndex = -1
    }

    // Position dropdown near cursor
    this.positionDropdown()
  },

  destroyed() {
    clearTimeout(this.debounceTimer)

    if (this.input) {
      this.input.removeEventListener("input", this.onInput)
      this.input.removeEventListener("keyup", this.onCursor)
      this.input.removeEventListener("click", this.onCursor)
      this.input.removeEventListener("keydown", this.onKeydown)
    }

    this.el.removeEventListener("egregoros:mention-select", this.onMentionSelect)
    this.destroyMirror()
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
    this.selectedIndex = -1
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
