const protocolVersion = "1"
const launchIdPattern = /^[A-Za-z0-9_-]{43}$/

const validBootstrap = (message, hostOrigin, appOrigin) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 3 &&
  message.type === "fediverse-miniapp:host-bootstrap" &&
  message.appOrigin === appOrigin &&
  !!message.bootstrap &&
  typeof message.bootstrap === "object" &&
  !Array.isArray(message.bootstrap) &&
  Object.keys(message.bootstrap).length === 8 &&
  message.bootstrap.type === "fediverse-miniapp:bootstrap" &&
  message.bootstrap.version === protocolVersion &&
  launchIdPattern.test(message.bootstrap.launchId || "") &&
  message.bootstrap.hostOrigin === hostOrigin &&
  message.bootstrap.issuer === hostOrigin &&
  message.bootstrap.authorizationServerMetadata ===
    `${hostOrigin}/.well-known/oauth-authorization-server` &&
  message.bootstrap.authorizationResultRelay === `${hostOrigin}/mini-apps/oauth/relay` &&
  Array.isArray(message.bootstrap.capabilities) &&
  message.bootstrap.capabilities.every(capability => typeof capability === "string")

export const createMiniAppFrameRelay = ({
  windowObject = window,
  parentWindow = windowObject.parent,
  iframe,
  hostOrigin,
  appOrigin,
}) => {
  let hostPort = null
  let appPort = null
  let bootstrap = null
  let frameLoaded = false

  const closeAppPort = () => {
    if (!appPort) return
    appPort.onmessage = null
    appPort.close()
    appPort = null
  }

  const onFrameLoad = () => {
    frameLoaded = true
    closeAppPort()
    if (!hostPort || !bootstrap || !iframe?.contentWindow) return

    const channel = new MessageChannel()
    appPort = channel.port1
    appPort.onmessage = event => hostPort?.postMessage(event.data)
    appPort.start?.()
    iframe.contentWindow.postMessage(bootstrap, appOrigin, [channel.port2])
  }

  const onHostMessage = event => {
    if (hostPort) return
    if (event?.origin !== hostOrigin || event?.source !== parentWindow) return
    if (event?.ports?.length !== 1 || !validBootstrap(event.data, hostOrigin, appOrigin)) return

    hostPort = event.ports[0]
    bootstrap = Object.freeze({...event.data.bootstrap})
    hostPort.onmessage = message => appPort?.postMessage(message.data)
    hostPort.start?.()
    if (frameLoaded) onFrameLoad()
  }

  windowObject.addEventListener("message", onHostMessage)
  iframe?.addEventListener("load", onFrameLoad)

  return {
    destroy: () => {
      closeAppPort()
      if (hostPort) {
        hostPort.onmessage = null
        hostPort.close()
        hostPort = null
      }
      bootstrap = null
      frameLoaded = false
      windowObject.removeEventListener("message", onHostMessage)
      iframe?.removeEventListener("load", onFrameLoad)
    },
  }
}
