import {
  createMiniAppBroker,
  validMiniAppLaunchInfo,
} from "../lib/mini_app_broker.mjs"
import {
  createMiniAppAuthRelay,
  openMiniAppAuthWindow,
} from "../lib/mini_app_auth_relay.mjs"
import {createMiniAppReadiness} from "../lib/mini_app_readiness.mjs"
import {bindMiniAppBrokerFrame} from "../lib/mini_app_host_frame.mjs"
import {selectEvmWalletAdapter} from "../wallet/evm_wallet_adapter.mjs"
import {evmWalletErrorCode} from "../wallet/evm_wallet_schema.mjs"
import {
  createWalletExecutionTracker,
  executeWalletRequest,
  normalizeWalletExecution,
} from "../wallet/wallet_execution_guard.mjs"

const parseLaunchInfo = value => {
  try {
    const launchInfo = JSON.parse(value || "null")
    return validMiniAppLaunchInfo(launchInfo) ? launchInfo : null
  } catch (_error) {
    return null
  }
}

const MiniAppHost = {
  mounted() {
    this.broker = null
    this.frame = null
    this.brokerKey = null
    this.brokerFailedKey = null
    this.walletAdapter = selectEvmWalletAdapter({ethereum: window.ethereum})
    this.walletExecutionTracker = createWalletExecutionTracker()
    this.walletCheckPending = false
    this.walletCompatible = null
    this.walletConfigKey = null
    this.walletGeneration = 0
    this.destroyedFlag = false
    this.readiness = createMiniAppReadiness({
      onTimeout: launchId =>
        this.pushEvent("mini_app_ready_timeout", {launch_id: launchId}),
    })
    this.authRelay = createMiniAppAuthRelay({
      sendResult: result =>
        this.pushEvent(
          "mini_app_auth_complete",
          {
            launch_id: result.launchId,
            request_id: result.requestId,
            status: result.status,
            ...(result.authorizationCode
              ? {authorization_code: result.authorizationCode}
              : {}),
          },
          reply => {
            if (!reply?.accepted) return

            if (result.status === "success" && !reply.authenticated) {
              const {
                handoffCode: _handoffCode,
                authorizationCode: _authorizationCode,
                ...failed
              } = result
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

      if (
        !this.authRelay.begin({
          launchId: this.el.dataset.launchId,
          requestId: button.dataset.requestId,
          state: button.dataset.authState,
          completionMode: button.dataset.authCompletionMode,
        })
      ) {
        completePopupFailure({
          type: "authResult",
          version: "1",
          launchId: this.el.dataset.launchId,
          requestId: button.dataset.requestId,
          status: "error",
        })
        return
      }

      if (
        !openMiniAppAuthWindow({
          windowObject: window,
          url: button.dataset.authUrl,
          requestId: button.dataset.requestId,
        })
      ) {
        this.authRelay.cancel()
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
        version: "1",
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
    this.handleEvent("mini_app_notification_permission_response", payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      this.broker?.send({
        type: "notificationPermissionResult",
        version: "1",
        launchId: payload.launch_id,
        requestId: payload.request_id,
        status: payload.status,
        ...(payload.status === "ok"
          ? {state: payload.state, actorUrl: payload.actor_url}
          : {}),
      })
    })
    this.handleEvent("mini_app_wallet_execute", async payload => {
      let execution
      try {
        execution = normalizeWalletExecution(payload, this.el.dataset.launchId)
      } catch (_error) {
        return
      }

      try {
        const completed = await executeWalletRequest(
          this.walletAdapter,
          payload,
          this.el.dataset.launchId,
          this.walletExecutionTracker
        )
        this.pushEvent("mini_app_wallet_execution_result", {
          launch_id: execution.launchId,
          request_id: completed.requestId,
          execution_token: completed.executionToken,
          method: completed.method,
          status: "ok",
          result: completed.result,
        })
      } catch (error) {
        const code = evmWalletErrorCode(error)
        if (code === 4100) return
        this.pushEvent("mini_app_wallet_execution_result", {
          launch_id: execution.launchId,
          request_id: execution.requestId,
          execution_token: execution.executionToken,
          method: execution.method,
          status: "error",
          code,
        })
      }
    })
    this.handleEvent("mini_app_wallet_preflight", async payload => {
      if (payload?.launch_id !== this.el.dataset.launchId) return

      try {
        const [chainId, accounts] = await Promise.all([
          this.walletAdapter.request({method: "eth_chainId", params: []}),
          this.walletAdapter.request({method: "eth_accounts", params: []}),
        ])
        this.pushEvent("mini_app_wallet_preflight_result", {
          launch_id: payload.launch_id,
          request_id: payload.request_id,
          status: "ok",
          chain_id: chainId,
          accounts,
        })
      } catch (_error) {
        this.pushEvent("mini_app_wallet_preflight_result", {
          launch_id: payload.launch_id,
          request_id: payload.request_id,
          status: "error",
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
    this.destroyedFlag = true
    this.walletGeneration += 1
    this.walletCheckPending = false
    this.destroyBroker()
    this.readiness.destroy()
    this.authRelay.destroy()
    this.el.removeEventListener("click", this.onHostClick)
  },

  destroyBroker() {
    this.broker?.destroy()
    this.readiness?.destroy()
    this.broker = null
    this.frame = null
    this.brokerKey = null
    this.brokerFailedKey = null
  },

  initializeWallet() {
    this.walletGeneration += 1
    const generation = this.walletGeneration
    this.walletCheckPending = false
    this.destroyBroker()
    this.authRelay.cancel()
    this.el.querySelector("#mini-app-frame-shell")?.replaceChildren()
    this.walletConfigKey = this.walletConfigurationKey()
    this.walletExecutionTracker = createWalletExecutionTracker()
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
      if (
        this.destroyedFlag ||
        this.walletGeneration !== generation ||
        this.walletConfigKey !== configKey
      ) {
        return
      }
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
    const shell = this.el.querySelector("#mini-app-frame-shell")
    const frame = shell?.querySelector("#mini-app-frame")
    const appOrigin = this.el.dataset.appOrigin || ""
    const launchId = this.el.dataset.launchId || ""
    const frameSrc = this.el.dataset.frameSrc || ""
    const frameTitle = this.el.dataset.frameTitle || ""
    const serializedLaunchInfo = this.el.dataset.launchInfo || ""
    const launchInfo = parseLaunchInfo(serializedLaunchInfo)
    const walletEnabled = this.el.dataset.walletEnabled === "true"
    const capabilities = []
    if (this.el.dataset.notificationsEnabled === "true") {
      capabilities.push("notifications.activitypub")
    }
    if (walletEnabled && this.walletAdapter.available() && this.walletCompatible !== false) {
      capabilities.push("wallet.evm")
    }
    const brokerKey = [
      appOrigin,
      launchId,
      frameSrc,
      frameTitle,
      serializedLaunchInfo,
      ...capabilities,
    ].join("\n")

    if (!shell || !appOrigin || !launchId || !launchInfo) {
      this.destroyBroker()
      this.authRelay.cancel()
      shell?.replaceChildren()
      return
    }

    if (frame && this.frame === frame && this.brokerKey === brokerKey) return
    if (!frame && this.brokerFailedKey === brokerKey) return

    this.destroyBroker()
    // Bound broker network hangs and fail-closed mount errors from the moment
    // navigation begins, not only after the iframe eventually fires `load`.
    this.readiness.loading(launchId)
    const binding = bindMiniAppBrokerFrame({
      shell,
      documentObject: document,
      createBroker: createMiniAppBroker,
      frameSrc,
      frameTitle,
      hostOrigin: window.location.origin,
      launchId,
      brokerOptions: {
        appOrigin,
        hostOrigin: window.location.origin,
        launchId,
        capabilities,
        launchInfo,
        onLoading: () => {
          this.authRelay.cancel()
          this.readiness.loading(launchId)
          this.pushEvent("mini_app_loading", {launch_id: launchId})
        },
        onReady: () => {
          this.readiness.ready(launchId)
          this.pushEvent("mini_app_ready", {launch_id: launchId})
        },
        onContextRequest: requestId =>
          this.pushEvent("mini_app_context_request", {
            launch_id: launchId,
            request_id: requestId,
          }),
        onNotificationPermissionRequest: request =>
          this.pushEvent("mini_app_notification_permission_request", {
            launch_id: launchId,
            request_id: request.requestId,
            action: request.action,
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
            completion_mode: request.completionMode,
            authorization_lifetime_seconds: request.authorizationLifetimeSeconds,
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
        onProtocolViolation: reason =>
          this.pushEvent("mini_app_protocol_violation", {
            launch_id: launchId,
            reason,
          }),
      },
    })
    if (!binding) {
      this.frame = null
      this.brokerKey = null
      this.brokerFailedKey = brokerKey
      this.broker = null
      return
    }
    this.frame = binding.frame
    this.brokerKey = brokerKey
    this.brokerFailedKey = null
    this.broker = binding.broker
  },
}

export default MiniAppHost
