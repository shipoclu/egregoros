const base64UrlEncode = bytes => {
  if (typeof btoa !== "function") {
    return Buffer.from(bytes)
      .toString("base64")
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "")
  }

  let binary = ""
  const len = bytes.length

  for (let i = 0; i < len; i++) binary += String.fromCharCode(bytes[i])

  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")
}

const base64UrlDecode = value => {
  if (typeof value !== "string" || value.length === 0) return new Uint8Array(0)

  if (typeof atob !== "function") {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/")
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "=")
    return new Uint8Array(Buffer.from(padded, "base64"))
  }

  const base64 = value.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "=")
  const binary = atob(padded)

  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

const utf8Bytes = value => new TextEncoder().encode(value)

const randomBytes = len => {
  const out = new Uint8Array(len)
  crypto.getRandomValues(out)
  return out
}

const sliceArrayBuffer = bytes => {
  const buffer = bytes.buffer
  return buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

const stableStringify = value => {
  if (value === null) return "null"
  if (typeof value === "number") return Number.isFinite(value) ? JSON.stringify(value) : "null"
  if (typeof value === "boolean") return value ? "true" : "false"
  if (typeof value === "string") return JSON.stringify(value)

  if (Array.isArray(value)) {
    return `[${value.map(item => stableStringify(item)).join(",")}]`
  }

  if (typeof value === "object") {
    const keys = Object.keys(value).sort()
    const entries = keys.map(key => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
    return `{${entries.join(",")}}`
  }

  return "null"
}

const deriveDmKey = async (myPrivateKey, otherPublicKey, saltBytes, infoBytes) => {
  const sharedBits = await crypto.subtle.deriveBits({name: "ECDH", public: otherPublicKey}, myPrivateKey, 256)
  const hkdfKey = await crypto.subtle.importKey("raw", sharedBits, "HKDF", false, ["deriveKey"])

  return crypto.subtle.deriveKey(
    {name: "HKDF", hash: "SHA-256", salt: saltBytes, info: infoBytes},
    hkdfKey,
    {name: "AES-GCM", length: 256},
    false,
    ["encrypt", "decrypt"]
  )
}

const encryptE2EEDM = async ({
  plaintext,
  senderApId,
  senderKid,
  senderPrivateKey,
  recipientApId,
  recipientKid,
  recipientJwk,
}) => {
  const recipientPublicKey = await crypto.subtle.importKey(
    "jwk",
    recipientJwk,
    {name: "ECDH", namedCurve: "P-256"},
    false,
    []
  )

  const salt = randomBytes(32)
  const nonce = randomBytes(12)
  const info = utf8Bytes("egregoros:e2ee:dm:v1")

  const aad = {
    sender_ap_id: senderApId,
    recipient_ap_id: recipientApId,
    sender_kid: senderKid,
    recipient_kid: recipientKid,
  }

  const aadBytes = utf8Bytes(stableStringify(aad))

  const key = await deriveDmKey(senderPrivateKey, recipientPublicKey, salt, info)

  const ciphertext = await crypto.subtle.encrypt(
    {name: "AES-GCM", iv: nonce, additionalData: aadBytes},
    key,
    utf8Bytes(plaintext)
  )

  return {
    version: 1,
    alg: "ECDH-P256+HKDF-SHA256+AES-256-GCM",
    sender: {ap_id: senderApId, kid: senderKid},
    recipient: {ap_id: recipientApId, kid: recipientKid},
    nonce: base64UrlEncode(nonce),
    salt: base64UrlEncode(salt),
    aad,
    ciphertext: base64UrlEncode(new Uint8Array(ciphertext)),
  }
}

const decryptE2EEDM = async ({payload, myPrivateKey, otherPublicJwk}) => {
  if (!otherPublicJwk) throw new Error("e2ee_missing_sender_key")

  const otherPublicKey = await crypto.subtle.importKey(
    "jwk",
    otherPublicJwk,
    {name: "ECDH", namedCurve: "P-256"},
    false,
    []
  )

  const saltBytes = base64UrlDecode(payload.salt)
  const nonceBytes = base64UrlDecode(payload.nonce)
  const infoBytes = utf8Bytes("egregoros:e2ee:dm:v1")
  const aadBytes = utf8Bytes(stableStringify(payload.aad || {}))
  const ciphertextBytes = base64UrlDecode(payload.ciphertext)

  const key = await deriveDmKey(myPrivateKey, otherPublicKey, saltBytes, infoBytes)

  const plaintext = await crypto.subtle.decrypt(
    {name: "AES-GCM", iv: nonceBytes, additionalData: aadBytes},
    key,
    sliceArrayBuffer(ciphertextBytes)
  )

  return new TextDecoder().decode(new Uint8Array(plaintext))
}

export {base64UrlDecode, base64UrlEncode, decryptE2EEDM, encryptE2EEDM}
