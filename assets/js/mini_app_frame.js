import {createMiniAppFrameRelay} from "./lib/mini_app_frame_relay.mjs"

export const mountMiniAppFrame = ({documentObject, windowObject, createRelay = createMiniAppFrameRelay}) => {
  const root = documentObject.querySelector("#mini-app-frame-root")
  const appOrigin = root?.dataset.appOrigin
  const launchUrl = root?.dataset.launchUrl
  if (!root || !appOrigin || !launchUrl) return null

  const iframe = documentObject.createElement("iframe")
  iframe.id = "mini-app-frame"
  iframe.title = root.dataset.frameTitle || "Mini app"
  iframe.referrerPolicy = "no-referrer"
  iframe.setAttribute("sandbox", "allow-scripts allow-forms allow-same-origin")
  iframe.setAttribute(
    "allow",
    "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'",
  )

  createRelay({
    windowObject,
    iframe,
    hostOrigin: windowObject.location.origin,
    appOrigin,
  })

  root.replaceChildren(iframe)
  iframe.src = launchUrl
  return iframe
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  mountMiniAppFrame({documentObject: document, windowObject: window})
}
