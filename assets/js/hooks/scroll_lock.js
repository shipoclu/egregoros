const lockCount = body => {
  if (!body) return 0
  const parsed = Number.parseInt(body.dataset.egregorosScrollLocks || "0", 10)
  return Number.isFinite(parsed) ? parsed : 0
}

export const lockScroll = () => {
  const body = document.body
  if (!body) return

  const count = lockCount(body)

  if (count === 0) {
    body.dataset.egregorosScrollOverflow = body.style.overflow || ""
    body.dataset.egregorosScrollPaddingRight = body.style.paddingRight || ""

    const scrollbarWidth = window.innerWidth - document.documentElement.clientWidth
    if (scrollbarWidth > 0) body.style.paddingRight = `${scrollbarWidth}px`

    body.style.overflow = "hidden"
  }

  body.dataset.egregorosScrollLocks = String(count + 1)
}

export const unlockScroll = () => {
  const body = document.body
  if (!body) return

  const count = lockCount(body)
  const next = Math.max(0, count - 1)

  if (next === 0) {
    body.style.overflow = body.dataset.egregorosScrollOverflow || ""
    body.style.paddingRight = body.dataset.egregorosScrollPaddingRight || ""

    delete body.dataset.egregorosScrollOverflow
    delete body.dataset.egregorosScrollPaddingRight
    delete body.dataset.egregorosScrollLocks
  } else {
    body.dataset.egregorosScrollLocks = String(next)
  }
}

