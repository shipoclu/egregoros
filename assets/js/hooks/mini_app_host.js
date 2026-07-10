import {createMiniAppBroker} from "../lib/mini_app_broker.mjs"

const MiniAppHost = {
  mounted() {
    this.broker = null
    this.frame = null
    this.brokerKey = null
    this.handleEvent("mini_app_context_response", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "contextResult",
        launchId: payload.launch_id,
        requestId: payload.request_id,
        status: payload.status,
        context: payload.context,
      })
    })
    this.bindFrame()
  },

  updated() {
    this.bindFrame()
  },

  destroyed() {
    this.destroyBroker()
  },

  destroyBroker() {
    this.broker?.destroy()
    this.broker = null
    this.frame = null
    this.brokerKey = null
  },

  bindFrame() {
    const frame = this.el.querySelector("#mini-app-frame")
    const appOrigin = this.el.dataset.appOrigin || ""
    const launchId = this.el.dataset.launchId || ""
    const brokerKey = `${appOrigin}\n${launchId}`

    if (!frame || !appOrigin || !launchId) {
      this.destroyBroker()
      return
    }

    if (this.frame === frame && this.brokerKey === brokerKey) return

    this.destroyBroker()
    this.frame = frame
    this.brokerKey = brokerKey
    this.broker = createMiniAppBroker({
      iframe: frame,
      appOrigin,
      launchId,
      onLoading: () => this.pushEvent("mini_app_loading", {launch_id: launchId}),
      onReady: () => this.pushEvent("mini_app_ready", {launch_id: launchId}),
      onContextRequest: requestId =>
        this.pushEvent("mini_app_context_request", {
          launch_id: launchId,
          request_id: requestId,
        }),
    })
  },
}

export default MiniAppHost
