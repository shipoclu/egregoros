const launchIdPattern = /^[A-Za-z0-9_-]{43}$/
const cardIdPattern = /^\/mini-apps\/broker\/[A-Za-z0-9_-]{1,64}$/
const resolutionTokenPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export const navigateMiniAppFrame = ({frame, frameSrc, hostOrigin, launchId}) => {
  try {
    if (!frame || typeof frameSrc !== "string" || !launchIdPattern.test(launchId || "")) {
      return false
    }

    const canonicalHostOrigin = new URL(hostOrigin).origin
    if (canonicalHostOrigin !== hostOrigin) return false

    const next = new URL(frameSrc, canonicalHostOrigin)
    const keys = [...next.searchParams.keys()]
    const resolutionTokens = next.searchParams.getAll("resolution_token")
    const launchIds = next.searchParams.getAll("launch_id")

    if (
      next.origin !== canonicalHostOrigin ||
      next.username ||
      next.password ||
      next.hash ||
      !cardIdPattern.test(next.pathname) ||
      keys.length !== 2 ||
      launchIds.length !== 1 ||
      launchIds[0] !== launchId ||
      resolutionTokens.length !== 1 ||
      !resolutionTokenPattern.test(resolutionTokens[0])
    ) {
      return false
    }

    const current = new URL(frame.src, canonicalHostOrigin)
    if (current.href === next.href) return false

    frame.src = next.href
    return true
  } catch (_error) {
    return false
  }
}
