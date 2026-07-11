import {createMiniAppFrameRelay} from "./lib/mini_app_frame_relay.mjs"

const iframe = document.querySelector("#mini-app-frame")

if (iframe) {
  createMiniAppFrameRelay({
    iframe,
    hostOrigin: window.location.origin,
    appOrigin: iframe.dataset.appOrigin,
  })
}
