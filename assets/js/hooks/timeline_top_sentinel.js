const TimelineTopSentinel = {
  mounted() {
    this.lastAtTop = null
    this.observer = new IntersectionObserver(entries => {
      const entry = entries[0]
      if (!entry) return

      const atTop = entry.isIntersecting
      if (this.lastAtTop === atTop) return

      this.lastAtTop = atTop
      this.pushEvent("timeline_at_top", {at_top: atTop})
    })

    this.observer.observe(this.el)
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
}

export default TimelineTopSentinel
