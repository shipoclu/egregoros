export const mediaWidthFor = (height, width) => Math.max(Math.round(Math.min(height * 1.5, width * 0.45)), 0)

const resizeMedia = hook => {
  const row = hook.media?.parentElement
  if (!row || !hook.image) return

  const {height, width} = row.getBoundingClientRect()
  hook.media.style.width = `${mediaWidthFor(height, width)}px`
}

export default {
  mounted() {
    this.media = this.el.querySelector('[data-role="mini-app-card-media"]')
    this.image = this.media?.querySelector("img")
    if (!this.media || !this.image) return

    this.resizeObserver = new ResizeObserver(() => resizeMedia(this))
    this.resizeObserver.observe(this.media.parentElement)
    resizeMedia(this)
  },

  updated() {
    resizeMedia(this)
  },

  destroyed() {
    this.resizeObserver?.disconnect()
  },
}
