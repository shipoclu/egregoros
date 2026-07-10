import {createMiniAppBroker} from "../lib/mini_app_broker.mjs"
import {createMiniAppAuthRelay} from "../lib/mini_app_auth_relay.mjs"

const MiniAppHost = {
  mounted() {
    this.broker = null
    this.frame = null
    this.brokerKey = null
    this.authRelay = createMiniAppAuthRelay({
      windowObject: window,
      sendResult: result => this.broker?.send(result),
      onComplete: result =>
        this.pushEvent("mini_app_auth_complete", {
          launch_id: result.launchId,
          request_id: result.requestId,
          status: result.status,
        }),
    })
    this.onHostClick = event => {
      const button = event.target.closest?.("[data-role='mini-app-auth-open']")
      if (!button || !this.el.contains(button)) return

      const popup = window.open(
        button.dataset.authUrl,
        `fediverse-miniapp-auth-${button.dataset.requestId}`,
        "popup=yes,width=520,height=720,resizable=yes,scrollbars=yes"
      )

      if (
        !this.authRelay.begin({
          popup,
          appOrigin: this.el.dataset.appOrigin,
          launchId: this.el.dataset.launchId,
          requestId: button.dataset.requestId,
        })
      ) {
        this.broker?.send({
          type: "authResult",
          version: "1",
          launchId: this.el.dataset.launchId,
          requestId: button.dataset.requestId,
          status: "error",
        })
        this.pushEvent("mini_app_auth_complete", {
          launch_id: this.el.dataset.launchId,
          request_id: button.dataset.requestId,
          status: "error",
        })
      }
    }
    this.el.addEventListener("click", this.onHostClick)
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
    this.handleEvent("mini_app_auth_response", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "authResult",
        version: "1",
        launchId: payload.launch_id,
        requestId: payload.request_id,
        status: payload.status,
      })
    })
    this.bindFrame()
  },

  updated() {
    this.bindFrame()
  },

  destroyed() {
    this.destroyBroker()
    this.authRelay.destroy()
    this.el.removeEventListener("click", this.onHostClick)
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
      this.authRelay.cancel()
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
      onLoading: () => {
        this.authRelay.cancel()
        this.pushEvent("mini_app_loading", {launch_id: launchId})
      },
      onReady: () => this.pushEvent("mini_app_ready", {launch_id: launchId}),
      onContextRequest: requestId =>
        this.pushEvent("mini_app_context_request", {
          launch_id: launchId,
          request_id: requestId,
        }),
      onAuthRequest: request =>
        this.pushEvent("mini_app_auth_request", {
          launch_id: launchId,
          request_id: request.requestId,
          client_id: request.clientId,
          redirect_uri: request.redirectUri,
          scopes: request.scopes,
          state: request.state,
          code_challenge: request.codeChallenge,
          code_challenge_method: request.codeChallengeMethod,
          handoff_challenge: request.handoffChallenge,
        }),
    })
  },
}

export default MiniAppHost
