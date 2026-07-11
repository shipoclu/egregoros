import {validEvmWalletPayload} from "../wallet/injected_evm_wallet_adapter.mjs"

const protocolVersion = "1"
const launchIdPattern = /^[A-Za-z0-9_-]{43}$/
const requestIdPattern = /^[A-Za-z0-9_-]{1,64}$/
const exactFields = (value, fields) => {
  const keys = Object.keys(value)
  return keys.length === fields.length && keys.every(key => fields.includes(key))
}

export const miniAppError = (code, message) =>
  Object.assign(new Error(message), {name: "MiniAppError", code})

const randomId = cryptoObject => {
  const bytes = cryptoObject.getRandomValues(new Uint8Array(16))
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")
}

const validOrigin = value => {
  try {
    return new URL(value).origin === value
  } catch (_error) {
    return false
  }
}

const validHttpsUrl = value => {
  if (typeof value !== "string" || value.length > 2048) return false
  try {
    const url = new URL(value)
    return url.protocol === "https:" && !!url.hostname && !url.username && !url.password && !url.hash
  } catch (_error) {
    return false
  }
}

const frozenBootstrap = message =>
  Object.freeze({
    version: message.version,
    launchId: message.launchId,
    hostOrigin: message.hostOrigin,
    issuer: message.issuer,
    authorizationServerMetadata: message.authorizationServerMetadata,
    capabilities: Object.freeze([...message.capabilities]),
  })

export const createFediverseMiniAppSDK = ({
  windowObject = window,
  parentWindow = windowObject.parent,
  navigatorObject = navigator,
  cryptoObject = crypto,
  allowedHostOrigin,
  timeoutMs = 30_000,
} = {}) => {
  if (typeof allowedHostOrigin !== "function") {
    throw miniAppError("HOST_VALIDATOR_REQUIRED", "An exact host-origin validator is required")
  }

  let port = null
  let bootstrapData = null
  let destroyed = false
  const pending = new Map()
  const listeners = new Map()
  const hostAllowed = origin => {
    try {
      return allowedHostOrigin(origin) === true
    } catch (_error) {
      return false
    }
  }
  let resolveConnect
  let rejectConnect
  const connected = new Promise((resolve, reject) => {
    resolveConnect = resolve
    rejectConnect = reject
  })

  const rejectPending = (code, message) => {
    for (const request of pending.values()) {
      clearTimeout(request.timer)
      request.reject(miniAppError(code, message))
    }
    pending.clear()
  }

  const emit = (name, payload) => {
    for (const callback of listeners.get(name) || []) callback(payload)
  }

  const settle = (message, correlationField, responseType, transform) => {
    const id = message?.[correlationField]
    const request = pending.get(id)
    if (!request || request.responseType !== responseType) return
    pending.delete(id)
    clearTimeout(request.timer)

    try {
      request.resolve(transform(message))
    } catch (error) {
      request.reject(error)
    }
  }

  const onPortMessage = event => {
    const message = event?.data
    if (
      !message ||
      typeof message !== "object" ||
      Array.isArray(message) ||
      message.version !== protocolVersion ||
      message.launchId !== bootstrapData.launchId
    ) {
      return
    }

    if (message.type === "contextResult") {
      if (
        !exactFields(message, [
          "type",
          "version",
          "launchId",
          "requestId",
          "status",
          "context",
        ]) ||
        !requestIdPattern.test(message.requestId || "") ||
        !["ok", "unavailable", "denied"].includes(message.status)
      ) {
        return
      }
      settle(message, "requestId", "contextResult", result => {
        if (result.status !== "ok") {
          throw miniAppError("CONTEXT_UNAVAILABLE", "Launch context was not released")
        }
        return result.context
      })
      return
    }

    if (message.type === "authResult") {
      const fields = ["type", "version", "launchId", "requestId", "status"]
      const validSuccess =
        message.status === "success" &&
        exactFields(message, [...fields, "handoffCode"]) &&
        typeof message.handoffCode === "string" &&
        /^[A-Za-z0-9_-]{16,512}$/.test(message.handoffCode)
      const validFailure =
        ["cancelled", "error", "invalid_request"].includes(message.status) &&
        exactFields(message, fields)
      if (!requestIdPattern.test(message.requestId || "") || (!validSuccess && !validFailure)) return
      settle(message, "requestId", "authResult", result => {
        if (result.status !== "success") {
          throw miniAppError("AUTH_FAILED", "Authentication did not complete")
        }
        return {status: result.status, handoffCode: result.handoffCode}
      })
      return
    }

    if (message.type === "composeNoteResult") {
      const baseFields = ["type", "version", "launchId", "callId", "status"]
      const valid =
        exactFields(message, baseFields) ||
        (exactFields(message, [...baseFields, "requestId"]) &&
          requestIdPattern.test(message.requestId || ""))
      if (!valid || !requestIdPattern.test(message.callId || "")) return
      settle(message, "callId", "composeNoteResult", result => ({
        status: result.status,
        ...(requestIdPattern.test(result.requestId || "") ? {requestId: result.requestId} : {}),
      }))
      return
    }

    if (message.type === "composeNotePublished") {
      if (
        exactFields(message, [
          "type",
          "version",
          "launchId",
          "requestId",
          "id",
          "scope",
        ]) &&
        requestIdPattern.test(message.requestId || "") &&
        typeof message.id === "string" &&
        ["public", "unlisted", "followers", "direct"].includes(message.scope)
      ) {
        emit("composeNotePublished", {
          requestId: message.requestId,
          id: message.id,
          scope: message.scope,
        })
      }
      return
    }

    if (message.type === "openExternalResult") {
      if (
        !exactFields(message, [
          "type",
          "version",
          "launchId",
          "requestId",
          "status",
        ]) ||
        !requestIdPattern.test(message.requestId || "") ||
        !["approved", "denied"].includes(message.status)
      ) {
        return
      }
      settle(message, "requestId", "openExternalResult", result => ({status: result.status}))
      return
    }

    if (message.type === "notificationPermissionResult") {
      if (
        !exactFields(message, [
          "type",
          "version",
          "launchId",
          "requestId",
          "state",
          "actorUrl",
        ]) ||
        !requestIdPattern.test(message.requestId || "") ||
        !["prompt", "granted", "denied"].includes(message.state) ||
        !validHttpsUrl(message.actorUrl)
      ) {
        return
      }
      settle(message, "requestId", "notificationPermissionResult", result => ({
        state: result.state,
        actorUrl: result.actorUrl,
      }))
      return
    }

    if (message.type === "walletResult") {
      const baseFields = ["type", "version", "launchId", "requestId"]
      const valid =
        exactFields(message, [...baseFields, "result"]) ||
        (exactFields(message, [...baseFields, "error"]) &&
          message.error &&
          typeof message.error === "object" &&
          !Array.isArray(message.error) &&
          exactFields(message.error, ["code", "message"]) &&
          Number.isInteger(message.error.code) &&
          typeof message.error.message === "string")
      if (!valid || !requestIdPattern.test(message.requestId || "")) return
      settle(message, "requestId", "walletResult", result => {
        if (result.error) {
          throw miniAppError(result.error.code, result.error.message || "Wallet request failed")
        }
        return result.result
      })
    }
  }

  const onBootstrap = event => {
    const message = event?.data
    if (destroyed || port) return
    if (event?.source !== parentWindow || event?.ports?.length !== 1) return
    if (!message || typeof message !== "object" || Array.isArray(message)) return
    if (
      Object.keys(message).length !== 7 ||
      message.type !== "fediverse-miniapp:bootstrap" ||
      message.version !== protocolVersion ||
      !launchIdPattern.test(message.launchId || "") ||
      event.origin !== message.hostOrigin ||
      !validOrigin(message.hostOrigin) ||
      message.issuer !== message.hostOrigin ||
      message.authorizationServerMetadata !==
        `${message.hostOrigin}/.well-known/oauth-authorization-server` ||
      !Array.isArray(message.capabilities) ||
      !message.capabilities.every(value => typeof value === "string") ||
      !hostAllowed(message.hostOrigin)
    ) {
      return
    }

    bootstrapData = frozenBootstrap(message)
    port = event.ports[0]
    port.onmessage = onPortMessage
    port.start?.()
    windowObject.removeEventListener("message", onBootstrap)
    resolveConnect(bootstrapData)
  }

  windowObject.addEventListener("message", onBootstrap)

  const send = async message => {
    await connected
    if (destroyed || !port) throw miniAppError("DESTROYED", "Mini app SDK was destroyed")
    port.postMessage({...message, version: protocolVersion, launchId: bootstrapData.launchId})
  }

  const request = async (message, responseType, correlationField = "requestId") => {
    await connected
    const id = randomId(cryptoObject)
    const envelope = {...message, [correlationField]: id}

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id)
        reject(miniAppError("TIMEOUT", `${message.type} timed out`))
      }, timeoutMs)

      pending.set(id, {resolve, reject, timer, responseType})
      send(envelope).catch(error => {
        clearTimeout(timer)
        pending.delete(id)
        reject(error)
      })
    })
  }

  const userActivation = () => navigatorObject?.userActivation?.isActive === true

  const requireCapability = capability => {
    if (!bootstrapData.capabilities.includes(capability)) {
      throw miniAppError("CAPABILITY_UNAVAILABLE", `${capability} capability is unavailable`)
    }
  }

  const provider = Object.freeze({
    request: async payload => {
      await connected
      if (!bootstrapData.capabilities.includes("wallet.evm")) {
        throw miniAppError(4200, "EVM wallet capability is unavailable")
      }
      if (!validEvmWalletPayload(payload || {})) {
        throw miniAppError(-32602, "Invalid wallet parameters")
      }

      if (
        ["eth_requestAccounts", "personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"].includes(
          payload.method
        ) &&
        !userActivation()
      ) {
        throw miniAppError(
          "USER_ACTIVATION_REQUIRED",
          "Privileged wallet requests require a user gesture"
        )
      }

      return request(
        {
          type: "walletRequest",
          method: payload.method,
          params: payload.params || [],
          userActivation: userActivation(),
        },
        "walletResult"
      )
    },
  })

  const sdk = {
    get bootstrap() {
      return bootstrapData
    },
    connect: () => connected,
    ready: () => send({type: "ready"}),
    getContext: () => request({type: "getContext"}, "contextResult"),
    requestAuth: auth =>
      request(
        {
          type: "requestAuth",
          clientId: auth?.clientId,
          redirectUri: auth?.redirectUri,
          scopes: auth?.scopes,
          state: auth?.state,
          codeChallenge: auth?.codeChallenge,
          codeChallengeMethod: "S256",
          handoffChallenge: auth?.handoffChallenge,
        },
        "authResult"
      ),
    composeNote: draft =>
      request({type: "composeNote", draft}, "composeNoteResult", "callId"),
    close: async () => {
      await send({type: "close", requestId: randomId(cryptoObject)})
    },
    openExternal: url => {
      if (!userActivation()) {
        return Promise.reject(
          miniAppError("USER_ACTIVATION_REQUIRED", "External navigation requires a user gesture")
        )
      }
      return request(
        {type: "openExternal", url, userActivation: true},
        "openExternalResult"
      )
    },
    on: (name, callback) => {
      if (typeof callback !== "function") return () => {}
      const callbacks = listeners.get(name) || new Set()
      callbacks.add(callback)
      listeners.set(name, callbacks)
      return () => callbacks.delete(callback)
    },
    wallet: Object.freeze({getProvider: () => provider}),
    notifications: Object.freeze({
      getPermission: async () => {
        await connected
        requireCapability("notifications.activitypub")
        return request(
          {type: "getNotificationPermission"},
          "notificationPermissionResult"
        )
      },
      requestPermission: async () => {
        await connected
        requireCapability("notifications.activitypub")
        if (!userActivation()) {
          throw miniAppError(
            "USER_ACTIVATION_REQUIRED",
            "Notification permission requires a user gesture"
          )
        }
        return request(
          {type: "requestNotificationPermission", userActivation: true},
          "notificationPermissionResult"
        )
      },
    }),
    destroy: () => {
      if (destroyed) return
      destroyed = true
      windowObject.removeEventListener("message", onBootstrap)
      port?.close()
      port = null
      rejectPending("DESTROYED", "Mini app SDK was destroyed")
      rejectConnect(miniAppError("DESTROYED", "Mini app SDK was destroyed"))
      listeners.clear()
    },
  }

  return Object.freeze(sdk)
}
