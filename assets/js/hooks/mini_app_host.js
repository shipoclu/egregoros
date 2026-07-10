import {createMiniAppBroker} from "../lib/mini_app_broker.mjs"
import {createMiniAppAuthRelay} from "../lib/mini_app_auth_relay.mjs"
import {selectEvmWalletAdapter} from "../wallet/evm_wallet_adapter.mjs"

const MiniAppHost = {
  mounted() {
    this.broker = null
    this.frame = null
    this.brokerKey = null
    this.walletAdapter = selectEvmWalletAdapter({ethereum: window.ethereum})
    this.walletCheckPending = false
    this.walletCompatible = null
    this.walletConfigKey = null
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
    this.handleEvent("mini_app_wallet_execute", async payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      try {
        const result = await this.walletAdapter.request({
          method: payload.method,
          params: payload.params,
        })
        this.pushEvent("mini_app_wallet_execution_result", {
          launch_id: payload.launch_id,
          request_id: payload.request_id,
          status: "ok",
          result,
        })
      } catch (error) {
        this.pushEvent("mini_app_wallet_execution_result", {
          launch_id: payload.launch_id,
          request_id: payload.request_id,
          status: "error",
          code: Number.isInteger(error?.code) ? error.code : 4001,
        })
      }
    })
    this.handleEvent("mini_app_wallet_response", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "walletResult",
        version: "1",
        launchId: payload.launch_id,
        requestId: payload.request_id,
        ...(payload.error ? {error: payload.error} : {result: payload.result}),
      })
    })
    this.initializeWallet()
  },

  updated() {
    if (this.walletConfigurationKey() !== this.walletConfigKey) {
      this.initializeWallet()
    } else {
      this.bindFrame()
    }
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

  initializeWallet() {
    this.walletConfigKey = this.walletConfigurationKey()
    const configKey = this.walletConfigKey
    const required = this.el.dataset.walletRequired === "true"
    if (!required) {
      this.walletCompatible = this.walletAdapter.available()
      this.bindFrame()
      return
    }

    this.walletCheckPending = true
    const launchId = this.el.dataset.launchId
    const requiredChains = JSON.parse(this.el.dataset.walletRequiredChains || "[]")
    const finish = compatible => {
      if (this.walletConfigKey !== configKey) return
      this.walletCompatible = compatible
      this.walletCheckPending = false
      this.pushEvent("mini_app_wallet_availability", {launch_id: launchId, compatible})
      this.bindFrame()
    }

    if (!this.walletAdapter.available()) {
      finish(false)
      return
    }

    this.walletAdapter
      .request({method: "eth_chainId", params: []})
      .then(chainId => {
        const caip2 = `eip155:${BigInt(chainId).toString(10)}`
        finish(requiredChains.length === 0 || requiredChains.includes(caip2))
      })
      .catch(() => finish(false))
  },

  walletConfigurationKey() {
    return [
      this.el.dataset.launchId || "",
      this.el.dataset.walletEnabled || "false",
      this.el.dataset.walletRequired || "false",
      this.el.dataset.walletRequiredChains || "[]",
    ].join("\n")
  },

  bindFrame() {
    if (this.walletCheckPending) return
    const frame = this.el.querySelector("#mini-app-frame")
    const appOrigin = this.el.dataset.appOrigin || ""
    const launchId = this.el.dataset.launchId || ""
    const brokerKey = `${appOrigin}\n${launchId}`
    const walletEnabled = this.el.dataset.walletEnabled === "true"
    const capabilities =
      walletEnabled && this.walletAdapter.available() && this.walletCompatible !== false
        ? ["wallet.evm"]
        : []

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
      capabilities,
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
      onWalletRequest: request =>
        this.pushEvent("mini_app_wallet_request", {
          launch_id: launchId,
          request_id: request.requestId,
          method: request.method,
          params: request.params,
        }),
    })
  },
}

export default MiniAppHost
