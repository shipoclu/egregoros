const protocolVersion = "1"

const validReadyMessage = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  message.type === "ready" &&
  message.launchId === launchId

const validRequestId = requestId =>
  typeof requestId === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(requestId)

export const createMiniAppBroker = ({
  iframe,
  appOrigin,
  launchId,
  onLoading,
  onReady,
  onContextRequest,
}) => {
  let hostPort = null
  let ready = false

  const closePort = () => {
    if (!hostPort) return
    hostPort.onmessage = null
    hostPort.close()
    hostPort = null
  }

  const start = () => {
    closePort()
    ready = false
    onLoading?.()

    const targetWindow = iframe?.contentWindow
    if (!targetWindow) return

    const channel = new MessageChannel()
    hostPort = channel.port1

    hostPort.onmessage = event => {
      const message = event?.data

      if (!ready && validReadyMessage(message, launchId)) {
        ready = true
        onReady?.()
        return
      }

      if (
        message?.type === "getContext" &&
        message?.launchId === launchId &&
        validRequestId(message?.requestId)
      ) {
        onContextRequest?.(message.requestId)
      }
    }

    hostPort.start?.()

    targetWindow.postMessage(
      {
        type: "fediverse-miniapp:bootstrap",
        version: protocolVersion,
        launchId,
        capabilities: [],
      },
      appOrigin,
      [channel.port2]
    )
  }

  iframe.addEventListener("load", start)

  return {
    send: message => hostPort?.postMessage(message),
    destroy: () => {
      iframe.removeEventListener("load", start)
      closePort()
    },
  }
}
