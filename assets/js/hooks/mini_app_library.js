export const MAX_RECENT_MINI_APPS = 12

const storageKey = userId => `egregoros:mini-app-library:${userId}`

const initial = name => name?.trim()?.charAt(0)?.toUpperCase() || "M"

const validEntry = value =>
  value &&
  typeof value === "object" &&
  typeof value.appOrigin === "string" &&
  typeof value.cardId === "string" &&
  typeof value.resolutionToken === "string" &&
  typeof value.name === "string"

export const recentEntries = (entries, entry) =>
  [entry, ...entries.filter(item => item.appOrigin !== entry.appOrigin)].slice(0, MAX_RECENT_MINI_APPS)

const loadEntries = userId => {
  try {
    const stored = JSON.parse(localStorage.getItem(storageKey(userId)) || "[]")
    return Array.isArray(stored) ? stored.filter(validEntry).slice(0, MAX_RECENT_MINI_APPS) : []
  } catch (_error) {
    return []
  }
}

const saveEntries = (userId, entries) => {
  try {
    localStorage.setItem(storageKey(userId), JSON.stringify(entries))
  } catch (_error) {
    // The tray remains usable for this page if browser storage is unavailable.
  }
}

const miniAppFromButton = button => {
  const {miniAppCardId, miniAppResolutionToken, miniAppOrigin, miniAppName, miniAppImageUrl} = button.dataset

  if (!miniAppCardId || !miniAppResolutionToken || !miniAppOrigin || !miniAppName) return null

  return {
    appOrigin: miniAppOrigin,
    cardId: miniAppCardId,
    resolutionToken: miniAppResolutionToken,
    name: miniAppName,
    imageUrl: miniAppImageUrl || null,
  }
}

export default {
  mounted() {
    this.userId = this.el.dataset.miniAppLibraryUserId
    if (!this.userId) return

    this.list = this.el.querySelector('[data-role="mini-app-library-list"]')
    this.empty = this.el.querySelector('[data-role="mini-app-library-empty"]')
    this.total = this.el.querySelector('[data-role="mini-app-library-total"]')
    this.badge = this.el.querySelector('[data-role="mini-app-library-count"]')
    this.entries = loadEntries(this.userId)

    this.onMiniAppOpen = event => {
      const entry = miniAppFromButton(event.target.closest("[data-mini-app-card-id]"))
      if (!entry) return

      this.entries = recentEntries(this.entries, entry)
      saveEntries(this.userId, this.entries)
      this.render()
    }

    this.onClick = event => {
      const button = event.target.closest("[data-mini-app-library-open]")
      if (!button) return

      const index = Number(button.dataset.miniAppLibraryOpen)
      const entry = this.entries[index]
      if (!entry) return

      this.el.removeAttribute("open")
      this.pushEvent("mini_app_open", {
        card_id: entry.cardId,
        resolution_token: entry.resolutionToken,
      })
    }

    document.addEventListener("egregoros:mini-app-open", this.onMiniAppOpen)
    this.el.addEventListener("click", this.onClick)
    this.render()
  },

  destroyed() {
    if (!this.userId) return

    document.removeEventListener("egregoros:mini-app-open", this.onMiniAppOpen)
    this.el.removeEventListener("click", this.onClick)
  },

  render() {
    const hasEntries = this.entries.length > 0
    this.total.textContent = String(this.entries.length)
    this.badge.classList.toggle("hidden", !hasEntries)
    this.empty.classList.toggle("hidden", hasEntries)
    this.list.classList.toggle("hidden", !hasEntries)
    this.list.replaceChildren(
      ...this.entries.map((entry, index) => {
        const button = document.createElement("button")
        button.type = "button"
        button.dataset.miniAppLibraryOpen = String(index)
        button.className =
          "flex w-full min-w-0 items-center gap-3 px-2 py-2 text-left transition hover:bg-[color:var(--bg-muted)] focus-visible:bg-[color:var(--bg-muted)] focus-visible:outline-none"

        const icon = document.createElement("span")
        icon.className =
          "relative flex size-10 shrink-0 items-center justify-center overflow-hidden border border-[color:var(--border-muted)] bg-[color:var(--bg-subtle)] font-bold text-[color:var(--accent)]"
        icon.textContent = initial(entry.name)

        if (entry.imageUrl?.startsWith("/mini-app-assets/")) {
          const image = document.createElement("img")
          image.src = entry.imageUrl
          image.alt = ""
          image.className = "absolute inset-0 size-full object-cover"
          image.addEventListener("error", () => image.remove())
          icon.append(image)
        }

        const copy = document.createElement("span")
        copy.className = "flex min-w-0 flex-1 flex-col"

        const name = document.createElement("strong")
        name.className = "truncate text-sm text-[color:var(--text-primary)]"
        name.textContent = entry.name

        const origin = document.createElement("small")
        origin.className = "truncate font-mono text-xs text-[color:var(--text-muted)]"
        origin.textContent = entry.appOrigin.replace(/^https:\/\//, "")

        copy.append(name, origin)
        button.append(icon, copy)
        return button
      }),
    )
  },
}
