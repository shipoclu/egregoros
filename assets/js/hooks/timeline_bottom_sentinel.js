const TimelineBottomSentinel = {
  mounted() {
    this.loading = false
    this.loader = this.findLoader()

    this.observer = new IntersectionObserver(
      entries => {
        const entry = entries[0]
        if (!entry || !entry.isIntersecting) return
        this.loadMore()
      },
      {rootMargin: "400px 0px"}
    )

    this.observer.observe(this.el)
  },

  updated() {
    this.loader = this.findLoader()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  findLoader() {
    return document.querySelector("[data-role='timeline-loading-more']")
  },

  setLoaderVisible(visible) {
    if (!this.loader) return
    const isVisible = !!visible
    this.loader.classList.toggle("hidden", !isVisible)
    this.loader.setAttribute("aria-hidden", isVisible ? "false" : "true")
  },

  loadMore() {
    if (this.loading) return

    this.loading = true
    this.setLoaderVisible(true)
    this.pushEvent("load_more", {}, () => {
      this.loading = false
      this.setLoaderVisible(false)
      if (!this.el.isConnected) return

      requestAnimationFrame(() => {
        if (this.isInView()) this.loadMore()
      })
    })
  },

  isInView() {
    const rect = this.el.getBoundingClientRect()
    return rect.top <= (window.innerHeight || document.documentElement.clientHeight)
  },
}

export default TimelineBottomSentinel
