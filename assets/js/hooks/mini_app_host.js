import {createMiniAppBroker} from "../lib/mini_app_broker.mjs"
import {createMiniAppAuthRelay} from "../lib/mini_app_auth_relay.mjs"

const MiniAppHost = {
  mounted() {
    this.broker = null
    this.frame = null
    this.brokerKey = null
    this.authRelay = createMiniAppAuthRelay({
      windowObject: window,
      sendResult: result =>
        this.pushEvent(
          "mini_app_auth_complete",
          {
            launch_id: result.launchId,
            request_id: result.requestId,
            status: result.status,
          },
          reply => {
            if (!reply?.accepted) return

            if (result.status === "success" && !reply.authenticated) {
              const {handoffCode: _handoffCode, ...failed} = result
              this.broker?.send({...failed, status: "error"})
            } else {
              this.broker?.send(result)
            }
          }
        ),
    })
    const completePopupFailure = result => {
      this.pushEvent(
        "mini_app_auth_complete",
        {
          launch_id: result.launchId,
          request_id: result.requestId,
          status: result.status,
        },
        reply => {
          if (reply?.accepted) this.broker?.send(result)
        }
      )
    }
    this.onHostClick = event => {
      const externalButton = event.target.closest?.("[data-role='mini-app-external-open']")
      if (externalButton && this.el.contains(externalButton)) {
        window.open(externalButton.dataset.externalUrl, "_blank", "noopener,noreferrer")
        return
      }

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
        completePopupFailure({
          type: "authResult",
          version: "1",
          launchId: this.el.dataset.launchId,
          requestId: button.dataset.requestId,
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
    this.handleEvent("mini_app_compose_response", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "composeNoteResult",
        version: "1",
        launchId: payload.launch_id,
        callId: payload.call_id,
        status: payload.status,
        ...(payload.request_id ? {requestId: payload.request_id} : {}),
      })
    })
    this.handleEvent("mini_app_compose_published", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "composeNotePublished",
        version: "1",
        launchId: payload.launch_id,
        requestId: payload.request_id,
        id: payload.id,
        scope: payload.scope,
      })
    })
    this.handleEvent("mini_app_external_response", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "openExternalResult",
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
      onComposeRequest: request =>
        this.pushEvent("mini_app_compose_request", {
          launch_id: launchId,
          call_id: request.callId,
          draft: request.draft,
        }),
      onCloseRequest: requestId =>
        this.pushEvent("mini_app_close_request", {
          launch_id: launchId,
          request_id: requestId,
        }),
      onExternalRequest: request =>
        this.pushEvent("mini_app_external_request", {
          launch_id: launchId,
          request_id: request.requestId,
          url: request.url,
        }),
    })
  },
}

export default MiniAppHost
