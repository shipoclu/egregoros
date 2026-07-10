const protocolVersion = "1"
const requestIdPattern = /^[A-Za-z0-9_-]{1,64}$/
const handoffCodePattern = /^[A-Za-z0-9_-]{16,512}$/
const callbackFields = new Set([
  "type",
  "version",
  "launchId",
  "requestId",
  "status",
  "handoffCode",
])

const validCallback = (message, pending) => {
  if (!message || typeof message !== "object" || Array.isArray(message)) return false
  if (!Object.keys(message).every(key => callbackFields.has(key))) return false
  if (message.type !== "fediverse-miniapp:auth-callback") return false
  if (message.version !== protocolVersion) return false
  if (message.launchId !== pending.launchId || message.requestId !== pending.requestId) return false
  if (!requestIdPattern.test(message.requestId)) return false

  if (message.status === "success") {
    return (
      Object.keys(message).length === callbackFields.size &&
      typeof message.handoffCode === "string" &&
      handoffCodePattern.test(message.handoffCode)
    )
  }

  return (
    ["cancelled", "error"].includes(message.status) &&
    Object.keys(message).length === callbackFields.size - 1 &&
    !("handoffCode" in message)
  )
}

export const createMiniAppAuthRelay = ({windowObject, sendResult, onComplete}) => {
  let pending = null

  const clear = ({closePopup = false} = {}) => {
    if (closePopup) pending?.popup?.close?.()
    pending = null
  }

  const onMessage = event => {
    if (!pending) return
    if (event?.origin !== pending.appOrigin || event?.source !== pending.popup) return
    if (!validCallback(event?.data, pending)) return

    const result = {
      type: "authResult",
      version: protocolVersion,
      launchId: pending.launchId,
      requestId: pending.requestId,
      status: event.data.status,
      ...(event.data.status === "success" ? {handoffCode: event.data.handoffCode} : {}),
    }
    const completion = {
      launchId: pending.launchId,
      requestId: pending.requestId,
      status: event.data.status,
    }

    sendResult?.(result)
    onComplete?.(completion)
    clear({closePopup: true})
  }

  windowObject.addEventListener("message", onMessage)

  return {
    begin: next => {
      if (
        !next?.popup ||
        typeof next.appOrigin !== "string" ||
        typeof next.launchId !== "string" ||
        !requestIdPattern.test(next.requestId)
      ) {
        return false
      }

      clear({closePopup: true})
      pending = {...next}
      return true
    },
    cancel: () => clear({closePopup: true}),
    destroy: () => {
      clear({closePopup: true})
      windowObject.removeEventListener("message", onMessage)
    },
  }
}
