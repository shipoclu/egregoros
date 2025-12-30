const TimelineBottomSentinel = {
  mounted() {
    this.loading = false

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

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  loadMore() {
    if (this.loading) return

    this.loading = true
    this.pushEvent("load_more", {}, () => {
      this.loading = false
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
