const protocolVersion = "1"
const launchIdPattern = /^[A-Za-z0-9_-]{43}$/
const requestIdPattern = /^[A-Za-z0-9_-]{1,64}$/
const statePattern = /^[A-Za-z0-9_-]{43,256}$/
const handoffCodePattern = /^[A-Za-z0-9_-]{16,512}$/
const authorizationCodePattern = /^[A-Za-z0-9_-]{43}$/
const completionType = "fediverse-miniapp:auth-completion"
const channelName = (launchId, state) => `fediverse-miniapp-auth:${launchId}:${state}`

const validCompletion = (message, launchId, state, expectedMode = null) => {
  if (!message || typeof message !== "object" || Array.isArray(message)) return false
  const keys = Object.keys(message)
  if (
    message.type !== completionType ||
    message.version !== protocolVersion ||
    message.launchId !== launchId ||
    message.state !== state
  ) {
    return false
  }

  if (message.status === "success") {
    const backendHandoff =
      keys.length === 6 &&
      keys.every(key =>
        ["type", "version", "launchId", "state", "status", "handoffCode"].includes(key)
      ) &&
      typeof message.handoffCode === "string" &&
      handoffCodePattern.test(message.handoffCode)
    const browserCode =
      keys.length === 6 &&
      keys.every(key =>
        ["type", "version", "launchId", "state", "status", "authorizationCode"].includes(key)
      ) &&
      typeof message.authorizationCode === "string" &&
      authorizationCodePattern.test(message.authorizationCode)

    if (expectedMode === "browser_code") return browserCode
    if (expectedMode === "backend_handoff") return backendHandoff
    return backendHandoff || browserCode
  }

  return (
    ["cancelled", "error"].includes(message.status) &&
    keys.length === 5 &&
    keys.every(key => ["type", "version", "launchId", "state", "status"].includes(key)) &&
    !("handoffCode" in message)
  )
}

const completionFromHash = hash => {
  if (typeof hash !== "string" || !hash.startsWith("#") || hash.length > 1024) return null
  const entries = [...new URLSearchParams(hash.slice(1)).entries()]
  const keys = entries.map(([key]) => key)
  if (new Set(keys).size !== keys.length) return null
  const values = Object.fromEntries(entries)

  const baseKeys = ["version", "launch_id", "state", "status"]
  const successField =
    "handoff_code" in values
      ? "handoff_code"
      : "authorization_code" in values
        ? "authorization_code"
        : null
  const expectedKeys = values.status === "success" && successField
    ? [...baseKeys, successField]
    : baseKeys
  if (keys.length !== expectedKeys.length || !keys.every(key => expectedKeys.includes(key))) return null
  if (
    values.version !== protocolVersion ||
    !launchIdPattern.test(values.launch_id || "") ||
    !statePattern.test(values.state || "")
  ) {
    return null
  }

  const message = {
    type: completionType,
    version: protocolVersion,
    launchId: values.launch_id,
    state: values.state,
    status: values.status,
    ...(values.status === "success" && successField === "handoff_code"
      ? {handoffCode: values.handoff_code}
      : {}),
    ...(values.status === "success" && successField === "authorization_code"
      ? {authorizationCode: values.authorization_code}
      : {}),
  }

  return validCompletion(message, values.launch_id, values.state) ? message : null
}

export const openMiniAppAuthWindow = ({windowObject = window, url, requestId}) => {
  if (
    typeof url !== "string" ||
    url.length === 0 ||
    url.length > 4096 ||
    !requestIdPattern.test(requestId || "")
  ) {
    return false
  }

  try {
    windowObject.open(
      url,
      `fediverse-miniapp-auth-${requestId}`,
      "noopener,noreferrer,popup=yes,width=520,height=720,resizable=yes,scrollbars=yes"
    )
    return true
  } catch (_error) {
    return false
  }
}

export const createMiniAppAuthRelay = ({
  broadcastChannelFactory = name => new BroadcastChannel(name),
  sendResult,
  onComplete,
}) => {
  let pending = null
  let channel = null

  const clear = () => {
    if (channel) {
      channel.onmessage = null
      channel.close?.()
      channel = null
    }
    pending = null
  }

  const begin = next => {
    clear()
    if (
      !next ||
      !launchIdPattern.test(next.launchId || "") ||
      !requestIdPattern.test(next.requestId || "") ||
      !statePattern.test(next.state || "") ||
      ![undefined, "backend_handoff", "browser_code"].includes(next.completionMode)
    ) {
      return false
    }

    try {
      channel = broadcastChannelFactory(channelName(next.launchId, next.state))
    } catch (_error) {
      channel = null
    }
    if (!channel || typeof channel !== "object") {
      clear()
      return false
    }

    pending = {
      launchId: next.launchId,
      requestId: next.requestId,
      state: next.state,
      completionMode: next.completionMode || "backend_handoff",
    }
    channel.onmessage = event => {
      if (
        !pending ||
        !validCompletion(
          event?.data,
          pending.launchId,
          pending.state,
          pending.completionMode
        )
      ) return

      const completion = {
        launchId: pending.launchId,
        requestId: pending.requestId,
        status: event.data.status,
      }
      const result = {
        type: "authResult",
        version: protocolVersion,
        ...completion,
        ...(event.data.status === "success" && pending.completionMode === "backend_handoff"
          ? {handoffCode: event.data.handoffCode}
          : {}),
        ...(event.data.status === "success" && pending.completionMode === "browser_code"
          ? {authorizationCode: event.data.authorizationCode}
          : {}),
      }

      clear()
      sendResult?.(result)
      onComplete?.(completion)
    }
    return true
  }

  return {
    begin,
    cancel: clear,
    destroy: clear,
  }
}

export const createMiniAppAuthCompletionRelay = ({
  locationObject = window.location,
  broadcastChannelFactory = name => new BroadcastChannel(name),
  schedule = (callback, delay) => setTimeout(callback, delay),
  closeWindow = () => window.close(),
} = {}) => {
  const message = completionFromHash(locationObject?.hash)
  if (!message) return false

  let channel
  try {
    channel = broadcastChannelFactory(channelName(message.launchId, message.state))
    channel.postMessage(message)
  } catch (_error) {
    channel?.close?.()
    return false
  }

  schedule(() => {
    channel.close?.()
    closeWindow()
  }, 100)
  return true
}
