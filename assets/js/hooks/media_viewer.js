const MediaViewer = {
  mounted() {
    this.index = this.readIndex()
    this.lastFocused = null

    this.onOpen = e => {
      const dispatcher = e.detail?.dispatcher
      if (!dispatcher) return

      this.lastFocused = document.activeElement

      const buttons = this.mediaButtons(dispatcher)
      if (buttons.length === 0) return

      const items = buttons.map(btn => this.itemFromButton(btn)).filter(Boolean)
      if (items.length === 0) return

      const selectedIndex = buttons.findIndex(btn => btn === dispatcher)
      this.setSlides(items)
      this.open()
      this.applyIndex(selectedIndex)
    }

    this.onNext = () => this.bump(1)
    this.onPrev = () => this.bump(-1)
    this.onClose = () => this.close()

    this.el.addEventListener("egregoros:media-open", this.onOpen)
    this.el.addEventListener("egregoros:media-next", this.onNext)
    this.el.addEventListener("egregoros:media-prev", this.onPrev)
    this.el.addEventListener("egregoros:media-close", this.onClose)

    this.onKeydown = e => {
      if (!this.el.isConnected) return
      if (e.defaultPrevented) return
      if (!this.isOpen()) return

      const target = e.target
      if (target && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))) {
        return
      }

      if (e.key === "Escape" || e.key === "Esc") {
        this.close()
        return
      }

      if (e.key === "ArrowRight") {
        this.bump(1)
        e.preventDefault()
        return
      }

      if (e.key === "ArrowLeft") {
        this.bump(-1)
        e.preventDefault()
      }
    }

    window.addEventListener("keydown", this.onKeydown)
    this.applyIndex(this.index)
  },

  updated() {
    if (!this.isOpen()) return
    this.applyIndex(this.index)
  },

  destroyed() {
    this.el.removeEventListener("egregoros:media-open", this.onOpen)
    this.el.removeEventListener("egregoros:media-next", this.onNext)
    this.el.removeEventListener("egregoros:media-prev", this.onPrev)
    this.el.removeEventListener("egregoros:media-close", this.onClose)
    window.removeEventListener("keydown", this.onKeydown)
  },

  readIndex() {
    const index = parseInt(this.el.dataset.index || "0", 10)
    return Number.isFinite(index) ? index : 0
  },

  isOpen() {
    return this.el.dataset.state === "open" && !this.el.classList.contains("hidden")
  },

  open() {
    this.el.classList.remove("hidden")
    this.el.dataset.state = "open"
    this.el.setAttribute("aria-hidden", "false")

    const closeButton = this.el.querySelector("[data-role='media-viewer-close']")
    if (closeButton) closeButton.focus({preventScroll: true})
  },

  close() {
    this.el.classList.add("hidden")
    this.el.dataset.state = "closed"
    this.el.setAttribute("aria-hidden", "true")
    this.clearSlides()
    this.restoreFocus()
  },

  restoreFocus() {
    if (!this.lastFocused) return
    const target = this.lastFocused
    this.lastFocused = null
    if (target.isConnected && typeof target.focus === "function") target.focus({preventScroll: true})
  },

  slides() {
    return Array.from(this.el.querySelectorAll("[data-role='media-viewer-slide']"))
  },

  mediaButtons(dispatcher) {
    const post = dispatcher.closest("article[id^='post-']")
    if (!post) return []

    return Array.from(post.querySelectorAll("button[data-role='attachment-open']")).sort((a, b) => {
      const aIndex = parseInt(a.dataset.index || "0", 10)
      const bIndex = parseInt(b.dataset.index || "0", 10)
      return aIndex - bIndex
    })
  },

  itemFromButton(button) {
    const img = button.querySelector("img[data-role='attachment'][data-kind='image']")
    if (img) {
      return {
        kind: "image",
        href: img.getAttribute("src") || "",
        description: img.getAttribute("alt") || "",
      }
    }

    const container = button.parentElement || button

    const video = container.querySelector("video[data-role='attachment'][data-kind='video']")
    if (video) {
      const source = video.querySelector("source")
      return {
        kind: "video",
        href: source?.getAttribute("src") || "",
        sourceType: source?.getAttribute("type") || "",
        description: video.getAttribute("aria-label") || "",
      }
    }

    const audio = container.querySelector("audio[data-role='attachment'][data-kind='audio']")
    if (audio) {
      const source = audio.querySelector("source")
      return {
        kind: "audio",
        href: source?.getAttribute("src") || "",
        sourceType: source?.getAttribute("type") || "",
        description: audio.getAttribute("aria-label") || "",
      }
    }

    return null
  },

  slidesContainer() {
    return this.el.querySelector("[data-role='media-viewer-slides']")
  },

  clearSlides() {
    const container = this.slidesContainer()
    if (container) container.replaceChildren()
    this.el.dataset.count = "0"
    this.updateControls(0)
  },

  setSlides(items) {
    const container = this.slidesContainer()
    if (!container) return

    container.replaceChildren(...items.map((item, index) => this.renderSlide(item, index)))
    this.el.dataset.count = String(items.length)
    this.updateControls(items.length)
  },

  updateControls(count) {
    const prev = this.el.querySelector("[data-role='media-viewer-prev']")
    const next = this.el.querySelector("[data-role='media-viewer-next']")

    const showNav = count > 1
    if (prev) prev.classList.toggle("hidden", !showNav)
    if (next) next.classList.toggle("hidden", !showNav)
  },

  renderSlide(item, index) {
    const slide = document.createElement("div")
    slide.dataset.role = "media-viewer-slide"
    slide.dataset.index = String(index)
    slide.dataset.state = "inactive"
    slide.setAttribute("aria-hidden", "true")
    slide.className = "w-full hidden"

    if (item.kind === "video") {
      const video = document.createElement("video")
      video.dataset.role = "media-viewer-item"
      video.controls = true
      video.preload = "metadata"
      video.playsInline = true
      video.className = "max-h-[85vh] w-full bg-black"
      if (item.description) video.setAttribute("aria-label", item.description)

      const source = document.createElement("source")
      source.setAttribute("src", item.href)
      if (item.sourceType) source.setAttribute("type", item.sourceType)
      video.appendChild(source)
      slide.appendChild(video)
      return slide
    }

    if (item.kind === "audio") {
      const wrapper = document.createElement("div")
      wrapper.className = "flex max-h-[85vh] w-full items-center justify-center bg-black/90 px-6 py-10"

      const audio = document.createElement("audio")
      audio.dataset.role = "media-viewer-item"
      audio.controls = true
      audio.preload = "metadata"
      audio.className = "w-full"
      if (item.description) audio.setAttribute("aria-label", item.description)

      const source = document.createElement("source")
      source.setAttribute("src", item.href)
      if (item.sourceType) source.setAttribute("type", item.sourceType)
      audio.appendChild(source)

      wrapper.appendChild(audio)
      slide.appendChild(wrapper)
      return slide
    }

    const img = document.createElement("img")
    img.dataset.role = "media-viewer-item"
    img.setAttribute("src", item.href)
    img.setAttribute("alt", item.description || "")
    img.loading = "lazy"
    img.className = "max-h-[85vh] w-full object-contain"
    slide.appendChild(img)
    return slide
  },

  bump(delta) {
    const slides = this.slides()
    if (slides.length < 2) return

    const count = slides.length
    const next = (this.index + delta + count) % count
    this.index = next
    this.el.dataset.index = String(next)

    this.applyIndex(next)
  },

  applyIndex(index) {
    const slides = this.slides()
    if (slides.length === 0) return

    const normalized = ((index % slides.length) + slides.length) % slides.length
    this.index = normalized
    this.el.dataset.index = String(normalized)

    slides.forEach(slide => {
      const slideIndex = parseInt(slide.dataset.index || "0", 10)
      const isActive = slideIndex === normalized
      slide.dataset.state = isActive ? "active" : "inactive"
      slide.classList.toggle("hidden", !isActive)
      slide.setAttribute("aria-hidden", isActive ? "false" : "true")
    })
  },
}

export default MediaViewer
