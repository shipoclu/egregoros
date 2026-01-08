const StatusAutoScroll = {
  mounted() {
    this.scrolled = false

    this.scrollIfNeeded = () => {
      if (this.scrolled) return
      if (!this.el || !this.el.isConnected) return
      if (window.location.hash) return

      const rect = this.el.getBoundingClientRect()
      const viewportHeight = window.innerHeight || 0

      const belowFold = rect.top > viewportHeight * 0.35
      const aboveFold = rect.bottom < viewportHeight * 0.1

      if (!belowFold && !aboveFold) return

      this.scrolled = true
      this.el.scrollIntoView({block: "start", behavior: "auto"})
    }

    requestAnimationFrame(() => requestAnimationFrame(this.scrollIfNeeded))
  },
}

export default StatusAutoScroll
