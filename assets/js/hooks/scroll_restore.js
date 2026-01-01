const ScrollRestore = {
  mounted() {
    this.onNavigation = () => this.storeScroll()
    window.addEventListener("phx:page-loading-start", this.onNavigation)
    window.addEventListener("beforeunload", this.onNavigation)
    this.restoreIfRequested()
  },

  destroyed() {
    window.removeEventListener("phx:page-loading-start", this.onNavigation)
    window.removeEventListener("beforeunload", this.onNavigation)
  },

  storeScroll() {
    const key = this.scrollKey()
    if (!key) return

    try {
      sessionStorage.setItem(key, String(window.scrollY || 0))
    } catch (_error) {
      // Ignore storage errors (private mode, disabled storage, etc.)
    }
  },

  scrollKey() {
    try {
      const url = new URL(window.location.href)
      url.searchParams.delete("restore_scroll")

      const query = url.searchParams.toString()
      return `egregoros:scroll:${url.pathname}${query ? `?${query}` : ""}`
    } catch (_error) {
      return null
    }
  },

  restoreIfRequested() {
    let url

    try {
      url = new URL(window.location.href)
    } catch (_error) {
      return
    }

    const shouldRestore = url.searchParams.get("restore_scroll") === "1"
    if (!shouldRestore) return

    const scrollKey = this.scrollKey()
    if (!scrollKey) return

    let stored

    try {
      stored = sessionStorage.getItem(scrollKey)
    } catch (_error) {
      return
    }

    const scrollTop = Number.parseInt(stored || "", 10)
    if (!Number.isFinite(scrollTop)) return

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        window.scrollTo({top: scrollTop, behavior: "auto"})
      })
    })

    const params = new URLSearchParams(url.searchParams)
    params.delete("restore_scroll")

    const query = params.toString()
    const cleaned = `${url.pathname}${query ? `?${query}` : ""}${url.hash}`

    try {
      window.history.replaceState(window.history.state, "", cleaned)
    } catch (_error) {
      // ignore
    }
  },
}

export default ScrollRestore
