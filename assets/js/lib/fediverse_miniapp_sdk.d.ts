export type MiniAppProtocolVersion = "1"
export type MiniAppCapability = "wallet.evm" | (string & {})
export type MiniAppVisibility = "public" | "unlisted" | "followers" | "direct"
export type Hex = `0x${string}`
export type EvmAddress = `0x${string}`

export interface MiniAppBootstrap {
  readonly version: MiniAppProtocolVersion
  readonly launchId: string
  readonly hostOrigin: string
  readonly issuer: string
  readonly authorizationServerMetadata: string
  readonly capabilities: readonly MiniAppCapability[]
}

export interface MiniAppLaunchNote {
  readonly id: string
  readonly url: string
  readonly content: string
  readonly author: string
  readonly mentions: readonly string[]
}

export interface MiniAppLaunchContext {
  readonly version: MiniAppProtocolVersion
  readonly launchUrl: string
  readonly sourceUrl: string
  readonly note: MiniAppLaunchNote
}

export interface MiniAppAuthorizationRequest {
  readonly clientId: string
  readonly redirectUri: string
  readonly scopes: readonly string[]
  readonly state: string
  readonly codeChallenge: string
  readonly handoffChallenge: string
}

export interface MiniAppAuthorizationResult {
  readonly status: "success"
  readonly handoffCode: string
}

export interface MiniAppComposeDraft {
  readonly text?: string
  readonly spoilerText?: string
  readonly language?: string
  readonly visibility?: MiniAppVisibility
  readonly inReplyTo?: string
  readonly links?: readonly string[]
}

export interface MiniAppComposeResult {
  readonly status: string
  readonly requestId?: string
}

export interface MiniAppComposePublishedReceipt {
  readonly requestId: string
  readonly id: string
  readonly scope: MiniAppVisibility
}

export interface EvmTransactionRequest {
  readonly from: EvmAddress
  readonly to?: EvmAddress
  readonly data?: Hex
  readonly value?: Hex
  readonly gas?: Hex
  readonly gasPrice?: Hex
  readonly maxFeePerGas?: Hex
  readonly maxPriorityFeePerGas?: Hex
  readonly nonce?: Hex
  readonly chainId?: Hex
}

export type EvmWalletRequest =
  | {readonly method: "eth_chainId"; readonly params?: readonly []}
  | {readonly method: "eth_accounts"; readonly params?: readonly []}
  | {readonly method: "eth_requestAccounts"; readonly params?: readonly []}
  | {
      readonly method: "personal_sign"
      readonly params: readonly [message: string, account: EvmAddress]
    }
  | {
      readonly method: "eth_signTypedData_v4"
      readonly params: readonly [account: EvmAddress, typedDataJson: string]
    }
  | {
      readonly method: "eth_sendTransaction"
      readonly params: readonly [transaction: EvmTransactionRequest]
    }

export interface MiniAppEvmProvider {
  request(args: {readonly method: "eth_chainId"; readonly params?: readonly []}): Promise<Hex>
  request(
    args: {
      readonly method: "eth_accounts" | "eth_requestAccounts"
      readonly params?: readonly []
    }
  ): Promise<EvmAddress[]>
  request(
    args: {
      readonly method: "personal_sign" | "eth_signTypedData_v4"
      readonly params: readonly [string, EvmAddress] | readonly [EvmAddress, string]
    }
  ): Promise<Hex>
  request(args: {
    readonly method: "eth_sendTransaction"
    readonly params: readonly [EvmTransactionRequest]
  }): Promise<Hex>
  request<T = unknown>(args: EvmWalletRequest): Promise<T>
}

export interface FediverseMiniAppSDK {
  readonly bootstrap: MiniAppBootstrap | null
  readonly wallet: {
    getProvider(): MiniAppEvmProvider
  }
  connect(): Promise<MiniAppBootstrap>
  ready(): Promise<void>
  getContext(): Promise<MiniAppLaunchContext>
  requestAuth(request: MiniAppAuthorizationRequest): Promise<MiniAppAuthorizationResult>
  composeNote(draft: MiniAppComposeDraft): Promise<MiniAppComposeResult>
  close(): Promise<void>
  openExternal(url: string): Promise<{readonly status: "approved" | "denied"}>
  on(
    event: "composeNotePublished",
    callback: (receipt: MiniAppComposePublishedReceipt) => void
  ): () => void
  destroy(): void
}

export interface CreateFediverseMiniAppSDKOptions {
  readonly allowedHostOrigin: (origin: string) => boolean
  readonly timeoutMs?: number
  readonly windowObject?: Window
  readonly parentWindow?: Window
  readonly navigatorObject?: Navigator
  readonly cryptoObject?: Crypto
}

export interface MiniAppError extends Error {
  readonly name: "MiniAppError"
  readonly code: string | number
}

export declare const miniAppError: (code: string | number, message: string) => MiniAppError

export declare const createFediverseMiniAppSDK: (
  options: CreateFediverseMiniAppSDKOptions
) => FediverseMiniAppSDK
