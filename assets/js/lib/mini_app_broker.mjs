import {
  normalizeEvmWalletPayload,
  privilegedEvmWalletMethod,
} from "../wallet/evm_wallet_schema.mjs"

const protocolVersion = "1"
const defaultLimits = Object.freeze({
  maxMessageBytes: 384 * 1024,
  maxTotalBytes: 2 * 1024 * 1024,
  maxMessages: 512,
  maxRequests: 128,
  maxOutstanding: 8,
  rateCapacity: 40,
  ratePerSecond: 20,
  maxDepth: 16,
  maxNodes: 4096,
})

const positiveLimit = (value, fallback) =>
  Number.isSafeInteger(value) && value > 0 ? value : fallback

const nonNegativeLimit = (value, fallback) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fallback

const brokerLimits = overrides => ({
  maxMessageBytes: positiveLimit(overrides?.maxMessageBytes, defaultLimits.maxMessageBytes),
  maxTotalBytes: positiveLimit(overrides?.maxTotalBytes, defaultLimits.maxTotalBytes),
  maxMessages: positiveLimit(overrides?.maxMessages, defaultLimits.maxMessages),
  maxRequests: positiveLimit(overrides?.maxRequests, defaultLimits.maxRequests),
  maxOutstanding: positiveLimit(overrides?.maxOutstanding, defaultLimits.maxOutstanding),
  rateCapacity: positiveLimit(overrides?.rateCapacity, defaultLimits.rateCapacity),
  ratePerSecond: nonNegativeLimit(overrides?.ratePerSecond, defaultLimits.ratePerSecond),
  maxDepth: positiveLimit(overrides?.maxDepth, defaultLimits.maxDepth),
  maxNodes: positiveLimit(overrides?.maxNodes, defaultLimits.maxNodes),
})

const boundedMessageBytes = (value, limits) => {
  const seen = new Set()
  const encoder = new TextEncoder()
  let bytes = 0
  let nodes = 0

  const add = count => {
    bytes += count
    return bytes <= limits.maxMessageBytes
  }

  const addString = string => {
    if (string.length > limits.maxMessageBytes - bytes) return false
    return add(encoder.encode(string).byteLength + 2)
  }

  const visit = (item, depth) => {
    nodes += 1
    if (nodes > limits.maxNodes || depth > limits.maxDepth) return false
    if (item === null) return add(4)
    if (typeof item === "string") return addString(item)
    if (typeof item === "boolean") return add(item ? 4 : 5)
    if (typeof item === "number") return Number.isFinite(item) && add(24)
    if (typeof item !== "object" || seen.has(item)) return false

    seen.add(item)
    if (Array.isArray(item)) {
      if (item.length > limits.maxNodes - nodes) return false
      let ownKeys = 0
      for (const key in item) {
        if (!Object.hasOwn(item, key)) continue
        ownKeys += 1
        if (ownKeys > item.length) return false
      }
      if (ownKeys !== item.length) return false
      if (!add(2 + Math.max(item.length - 1, 0))) return false
      for (const entry of item) if (!visit(entry, depth + 1)) return false
      return true
    }

    const prototype = Object.getPrototypeOf(item)
    if (prototype !== Object.prototype && prototype !== null) return false
    if (!add(2)) return false
    let entries = 0
    for (const key in item) {
      if (!Object.hasOwn(item, key)) continue
      entries += 1
      if (entries > limits.maxNodes - nodes) return false
      if (entries > 1 && !add(1)) return false
      if (!addString(key) || !add(1) || !visit(item[key], depth + 1)) return false
    }
    return true
  }

  return visit(value, 0) ? bytes : null
}

const validReadyMessage = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 3 &&
  message.type === "ready" &&
  message.version === protocolVersion &&
  message.launchId === launchId

const validContextRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 4 &&
  Object.keys(message).every(key => ["type", "version", "launchId", "requestId"].includes(key)) &&
  message.type === "getContext" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId)

const validLaunchInfoRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 4 &&
  Object.keys(message).every(key => ["type", "version", "launchId", "requestId"].includes(key)) &&
  message.type === "getLaunchInfo" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId)

const validLaunchUrl = (value, {allowFragment = false} = {}) => {
  if (typeof value !== "string" || value.length > 2048) return false
  try {
    const url = new URL(value)
    return (
      url.protocol === "https:" &&
      !!url.hostname &&
      !url.username &&
      !url.password &&
      (allowFragment || !url.hash)
    )
  } catch (_error) {
    return false
  }
}

const validSourceNoteId = value => {
  if (typeof value !== "string" || value.length > 2048) return false
  try {
    const url = new URL(value)
    return (
      ["http:", "https:"].includes(url.protocol) &&
      !!url.hostname &&
      !url.username &&
      !url.password &&
      !url.hash
    )
  } catch (_error) {
    return false
  }
}

export const validMiniAppLaunchInfo = value =>
  !!value &&
  typeof value === "object" &&
  !Array.isArray(value) &&
  Object.keys(value).length === 4 &&
  Object.keys(value).every(key =>
    ["version", "launchUrl", "linkedUrl", "sourceNoteId"].includes(key)
  ) &&
  value.version === protocolVersion &&
  validLaunchUrl(value.launchUrl, {allowFragment: true}) &&
  validLaunchUrl(value.linkedUrl, {allowFragment: true}) &&
  validSourceNoteId(value.sourceNoteId)

const validNotificationPermissionGetRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 4 &&
  Object.keys(message).every(key => ["type", "version", "launchId", "requestId"].includes(key)) &&
  message.type === "getNotificationPermission" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId)

const validNotificationPermissionPromptRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 5 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "requestId", "userActivation"].includes(key)
  ) &&
  message.type === "requestNotificationPermission" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId) &&
  message.userActivation === true

const validRequestId = requestId =>
  typeof requestId === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(requestId)

const authRequestFields = new Set([
  "type",
  "version",
  "launchId",
  "requestId",
  "clientId",
  "redirectUri",
  "scopes",
  "state",
  "codeChallenge",
  "codeChallengeMethod",
  "handoffChallenge",
  "completionMode",
  "authorizationLifetimeSeconds",
])

const boundedUrl = value => typeof value === "string" && value.length <= 2048
const base64UrlSha256 = value =>
  typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value)
const highEntropyState = value =>
  typeof value === "string" && /^[A-Za-z0-9_-]{43,256}$/.test(value)
const validScopes = scopes =>
  Array.isArray(scopes) &&
  scopes.length >= 1 &&
  scopes.length <= 32 &&
  new Set(scopes).size === scopes.length &&
  scopes.every(scope =>
    typeof scope === "string" && /^[A-Za-z][A-Za-z0-9:_-]{0,63}$/.test(scope)
  )

const validAuthRequest = (message, launchId) => {
  if (
    !message ||
    typeof message !== "object" ||
    Array.isArray(message) ||
    !Object.keys(message).every(key => authRequestFields.has(key)) ||
    message.type !== "requestAuth" ||
    message.version !== protocolVersion ||
    message.launchId !== launchId ||
    !validRequestId(message.requestId) ||
    typeof message.clientId !== "string" ||
    !/^[A-Za-z0-9_-]{10,200}$/.test(message.clientId) ||
    !boundedUrl(message.redirectUri) ||
    !validScopes(message.scopes) ||
    !highEntropyState(message.state) ||
    !base64UrlSha256(message.codeChallenge) ||
    message.codeChallengeMethod !== "S256" ||
    (message.authorizationLifetimeSeconds !== undefined &&
      (!Number.isSafeInteger(message.authorizationLifetimeSeconds) ||
        message.authorizationLifetimeSeconds < 300 ||
        message.authorizationLifetimeSeconds > 31_536_000))
  ) {
    return false
  }

  const completionMode = message.completionMode || "backend_handoff"
  if (completionMode === "browser_code") {
    return !("handoffChallenge" in message)
  }
  if (completionMode === "backend_handoff") {
    return base64UrlSha256(message.handoffChallenge)
  }
  return false
}

const validSessionRestoreRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 6 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "requestId", "clientId", "restoreChallenge"].includes(key)
  ) &&
  message.type === "restoreSession" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId) &&
  typeof message.clientId === "string" &&
  /^[A-Za-z0-9_-]{10,200}$/.test(message.clientId) &&
  base64UrlSha256(message.restoreChallenge)

const composeDraftFields = new Set([
  "text",
  "spoilerText",
  "language",
  "visibility",
  "inReplyTo",
  "links",
])
const composeVisibilities = new Set(["public", "unlisted", "followers", "direct"])
const validOptionalString = (value, max) => value === undefined || (typeof value === "string" && value.length <= max)
const validHttpsUrl = value => {
  if (typeof value !== "string" || value.length > 2048) return false
  try {
    const url = new URL(value)
    return url.protocol === "https:" && !!url.hostname && !url.username && !url.password
  } catch (_error) {
    return false
  }
}
const validComposeDraft = draft =>
  !!draft &&
  typeof draft === "object" &&
  !Array.isArray(draft) &&
  Object.keys(draft).every(key => composeDraftFields.has(key)) &&
  validOptionalString(draft.text, 5000) &&
  validOptionalString(draft.spoilerText, 500) &&
  (draft.language === undefined ||
    draft.language === "" ||
    (typeof draft.language === "string" &&
      draft.language.length <= 35 &&
      /^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(draft.language))) &&
  (draft.visibility === undefined || composeVisibilities.has(draft.visibility)) &&
  (draft.inReplyTo === undefined || validHttpsUrl(draft.inReplyTo)) &&
  (draft.links === undefined ||
    (Array.isArray(draft.links) &&
      draft.links.length <= 8 &&
      draft.links.every(validHttpsUrl)))

const validComposeRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 5 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "callId", "draft"].includes(key)
  ) &&
  message.type === "composeNote" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.callId) &&
  validComposeDraft(message.draft)

const validCloseRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 4 &&
  Object.keys(message).every(key => ["type", "version", "launchId", "requestId"].includes(key)) &&
  message.type === "close" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId)

const validExternalRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 6 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "requestId", "url", "userActivation"].includes(key)
  ) &&
  message.type === "openExternal" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId) &&
  validHttpsUrl(message.url) &&
  message.userActivation === true

const normalizeWalletMessagePayload = message => {
  try {
    return normalizeEvmWalletPayload({method: message.method, params: message.params})
  } catch (_error) {
    return null
  }
}

const validWalletRequest = (message, launchId) => {
  if (
    !message ||
    typeof message !== "object" ||
    Array.isArray(message) ||
    Object.keys(message).length !== 7 ||
    !Object.keys(message).every(key =>
      ["type", "version", "launchId", "requestId", "method", "params", "userActivation"].includes(key)
    ) ||
    message.type !== "walletRequest" ||
    message.version !== protocolVersion ||
    message.launchId !== launchId ||
    !validRequestId(message.requestId) ||
    typeof message.userActivation !== "boolean"
  ) {
    return false
  }
  const payload = normalizeWalletMessagePayload(message)
  return !!payload && (!privilegedEvmWalletMethod(payload.method) || message.userActivation === true)
}

export const createMiniAppBroker = ({
  iframe,
  appOrigin,
  hostOrigin,
  launchId,
  capabilities = [],
  launchInfo,
  onLoading,
  onReady,
  onContextRequest,
  onNotificationPermissionRequest,
  onAuthRequest,
  onSessionRestoreRequest,
  onComposeRequest,
  onCloseRequest,
  onExternalRequest,
  onWalletRequest,
  onProtocolViolation,
  limits: limitOverrides,
  now = () => performance.now(),
}) => {
  const limits = brokerLimits(limitOverrides)
  let hostPort = null
  let ready = false
  let seenRequests = new Set()
  let outstandingRequests = new Set()
  let totalBytes = 0
  let messageCount = 0
  let rateTokens = limits.rateCapacity
  let rateUpdatedAt = now()
  let violated = false

  const closePort = () => {
    if (!hostPort) return
    hostPort.onmessage = null
    hostPort.close()
    hostPort = null
  }

  const violate = reason => {
    if (violated) return
    violated = true
    closePort()
    onProtocolViolation?.(reason)
  }

  const consumeBytes = message => {
    const bytes = boundedMessageBytes(message, limits)
    if (bytes === null) {
      violate("message_bytes")
      return false
    }
    if (totalBytes + bytes > limits.maxTotalBytes) {
      violate("total_bytes")
      return false
    }
    totalBytes += bytes
    return true
  }

  const consumeInbound = message => {
    if (messageCount >= limits.maxMessages) {
      violate("message_count")
      return false
    }

    const current = now()
    const elapsed = Math.max(current - rateUpdatedAt, 0)
    rateTokens = Math.min(
      limits.rateCapacity,
      rateTokens + (elapsed * limits.ratePerSecond) / 1000
    )
    rateUpdatedAt = current
    if (rateTokens < 1) {
      violate("rate_limit")
      return false
    }

    rateTokens -= 1
    messageCount += 1
    return consumeBytes(message)
  }

  const acceptOnce = (key, {trackOutstanding = true} = {}) => {
    if (seenRequests.has(key)) return false
    if (seenRequests.size >= limits.maxRequests) {
      violate("request_count")
      return false
    }
    if (trackOutstanding && outstandingRequests.size >= limits.maxOutstanding) {
      violate("outstanding")
      return false
    }
    seenRequests.add(key)
    if (trackOutstanding) outstandingRequests.add(key)
    return true
  }

  const responseRequestKey = message => {
    if (!message || typeof message !== "object" || Array.isArray(message)) return null
    if (message.launchId !== launchId) return null

    if (message.type === "contextResult") return `context:${message.requestId}`
    if (message.type === "notificationPermissionResult") return `notification:${message.requestId}`
    if (message.type === "authResult") return `auth:${message.requestId}`
    if (message.type === "sessionRestoreResult") return `restore:${message.requestId}`
    if (message.type === "composeNoteResult") return `compose:${message.callId}`
    if (message.type === "openExternalResult") return `external:${message.requestId}`
    if (message.type === "walletResult") return `wallet:${message.requestId}`
    return null
  }

  const start = () => {
    closePort()
    ready = false
    if (violated) return
    onLoading?.()

    const targetWindow = iframe?.contentWindow
    if (!targetWindow) return

    const channel = new MessageChannel()
    hostPort = channel.port1

    hostPort.onmessage = event => {
      const message = event?.data
      if (!consumeInbound(message)) return

      if (!ready && validReadyMessage(message, launchId)) {
        ready = true
        onReady?.()
        return
      }

      if (!ready) {
        violate("ready_required")
        return
      }

      if (validReadyMessage(message, launchId)) return

      if (
        validLaunchInfoRequest(message, launchId) &&
        acceptOnce(`launch-info:${message.requestId}`, {trackOutstanding: false})
      ) {
        if (!validMiniAppLaunchInfo(launchInfo)) {
          violate("launch_info")
          return
        }
        hostPort.postMessage({
          type: "launchInfoResult",
          version: protocolVersion,
          launchId,
          requestId: message.requestId,
          launchInfo,
        })
        return
      }

      if (
        validContextRequest(message, launchId) &&
        acceptOnce(`context:${message.requestId}`)
      ) {
        onContextRequest?.(message.requestId)
        return
      }

      if (capabilities.includes("notifications.activitypub")) {
        if (
          validNotificationPermissionGetRequest(message, launchId) &&
          acceptOnce(`notification:${message.requestId}`)
        ) {
          onNotificationPermissionRequest?.({requestId: message.requestId, action: "get"})
          return
        }

        if (
          validNotificationPermissionPromptRequest(message, launchId) &&
          acceptOnce(`notification:${message.requestId}`)
        ) {
          onNotificationPermissionRequest?.({requestId: message.requestId, action: "request"})
          return
        }
      }

      if (validAuthRequest(message, launchId) && acceptOnce(`auth:${message.requestId}`)) {
        onAuthRequest?.({
          requestId: message.requestId,
          clientId: message.clientId,
          redirectUri: message.redirectUri,
          scopes: [...message.scopes],
          state: message.state,
          codeChallenge: message.codeChallenge,
          codeChallengeMethod: message.codeChallengeMethod,
          ...(message.completionMode === "browser_code"
            ? {completionMode: "browser_code"}
            : {handoffChallenge: message.handoffChallenge}),
          ...(message.authorizationLifetimeSeconds === undefined
            ? {}
            : {authorizationLifetimeSeconds: message.authorizationLifetimeSeconds}),
        })
        return
      }

      if (
        validSessionRestoreRequest(message, launchId) &&
        acceptOnce(`restore:${message.requestId}`)
      ) {
        onSessionRestoreRequest?.({
          requestId: message.requestId,
          clientId: message.clientId,
          restoreChallenge: message.restoreChallenge,
        })
        return
      }

      if (validComposeRequest(message, launchId) && acceptOnce(`compose:${message.callId}`)) {
        onComposeRequest?.({callId: message.callId, draft: {...message.draft}})
        return
      }

      if (
        validCloseRequest(message, launchId) &&
        acceptOnce(`close:${message.requestId}`, {trackOutstanding: false})
      ) {
        onCloseRequest?.(message.requestId)
        return
      }

      if (validExternalRequest(message, launchId) && acceptOnce(`external:${message.requestId}`)) {
        onExternalRequest?.({requestId: message.requestId, url: message.url})
        return
      }

      if (
        capabilities.includes("wallet.evm") &&
        validWalletRequest(message, launchId) &&
        acceptOnce(`wallet:${message.requestId}`)
      ) {
        const payload = normalizeWalletMessagePayload(message)
        onWalletRequest?.({
          requestId: message.requestId,
          method: payload.method,
          params: payload.params,
        })
      }
    }

    hostPort.start?.()

    const bootstrap = {
        type: "fediverse-miniapp:bootstrap",
        version: protocolVersion,
        launchId,
        hostOrigin,
        issuer: hostOrigin,
        authorizationServerMetadata: `${hostOrigin}/.well-known/oauth-authorization-server`,
        authorizationResultRelay: `${hostOrigin}/mini-apps/oauth/relay`,
        capabilities: [...capabilities],
      }

    targetWindow.postMessage(
      {
        type: "fediverse-miniapp:host-bootstrap",
        appOrigin,
        bootstrap,
      },
      hostOrigin,
      [channel.port2]
    )
  }

  iframe.addEventListener("load", start)

  return {
    send: message => {
      if (
        !hostPort ||
        !ready ||
        violated ||
        !message ||
        typeof message !== "object" ||
        Array.isArray(message) ||
        message.launchId !== launchId
      ) {
        return false
      }
      const requestKey = responseRequestKey(message)
      if (requestKey) {
        if (!outstandingRequests.has(requestKey)) return false
      }
      if (!consumeBytes(message)) return false
      if (requestKey) {
        outstandingRequests.delete(requestKey)
      }
      hostPort.postMessage(message)
      return true
    },
    destroy: () => {
      iframe.removeEventListener("load", start)
      closePort()
    },
  }
}
