import {navigateMiniAppFrame} from "./mini_app_frame_navigation.mjs"

const createBrokerFrame = (documentObject, title) => {
  const frame = documentObject.createElement("iframe")
  frame.id = "mini-app-frame"
  frame.title = title || "Mini app"
  frame.referrerPolicy = "no-referrer"
  frame.className = "h-full w-full border-0"
  return frame
}

export const bindMiniAppBrokerFrame = ({
  shell,
  documentObject,
  createBroker,
  brokerOptions,
  frameSrc,
  frameTitle,
  hostOrigin,
  launchId,
}) => {
  if (!shell) return null

  const frame = createBrokerFrame(documentObject, frameTitle)

  // Bind the load handler and the exact-origin broker before assigning src or
  // attaching a newly-created iframe, so no document can win a load race.
  const broker = createBroker({...brokerOptions, iframe: frame})
  const navigated = navigateMiniAppFrame({
    frame,
    frameSrc,
    hostOrigin,
    launchId,
  })

  if (!navigated) {
    broker.destroy()
    shell.replaceChildren()
    return null
  }

  shell.replaceChildren(frame)
  return {frame, broker}
}
