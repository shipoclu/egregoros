import assert from "node:assert/strict"
import test from "node:test"

import {base64UrlDecode, base64UrlEncode, decryptE2EEDM, encryptE2EEDM} from "../js/lib/e2ee_dm.mjs"

const generateEcdhKeyPair = async () =>
  crypto.subtle.generateKey({name: "ECDH", namedCurve: "P-256"}, true, ["deriveBits"])

test("E2EE DM encrypt/decrypt roundtrip", async () => {
  const sender = await generateEcdhKeyPair()
  const recipient = await generateEcdhKeyPair()

  const senderPublicJwk = await crypto.subtle.exportKey("jwk", sender.publicKey)
  const recipientPublicJwk = await crypto.subtle.exportKey("jwk", recipient.publicKey)

  const payload = await encryptE2EEDM({
    plaintext: "hello, encrypted world ✨",
    senderApId: "https://example.com/users/alice",
    senderKid: "e2ee-alice",
    senderPrivateKey: sender.privateKey,
    recipientApId: "https://example.net/users/bob",
    recipientKid: "e2ee-bob",
    recipientJwk: recipientPublicJwk,
  })

  const plaintext = await decryptE2EEDM({
    payload,
    myPrivateKey: recipient.privateKey,
    otherPublicJwk: senderPublicJwk,
  })

  assert.equal(plaintext, "hello, encrypted world ✨")
})

test("E2EE DM decrypt rejects tampered ciphertext", async () => {
  const sender = await generateEcdhKeyPair()
  const recipient = await generateEcdhKeyPair()

  const senderPublicJwk = await crypto.subtle.exportKey("jwk", sender.publicKey)
  const recipientPublicJwk = await crypto.subtle.exportKey("jwk", recipient.publicKey)

  const payload = await encryptE2EEDM({
    plaintext: "test tamper",
    senderApId: "https://example.com/users/alice",
    senderKid: "e2ee-alice",
    senderPrivateKey: sender.privateKey,
    recipientApId: "https://example.net/users/bob",
    recipientKid: "e2ee-bob",
    recipientJwk: recipientPublicJwk,
  })

  const bytes = base64UrlDecode(payload.ciphertext)
  bytes[0] ^= 0b0000_0001
  payload.ciphertext = base64UrlEncode(bytes)

  await assert.rejects(() =>
    decryptE2EEDM({
      payload,
      myPrivateKey: recipient.privateKey,
      otherPublicJwk: senderPublicJwk,
    })
  )
})

test("E2EE DM decrypt rejects tampered AAD", async () => {
  const sender = await generateEcdhKeyPair()
  const recipient = await generateEcdhKeyPair()

  const senderPublicJwk = await crypto.subtle.exportKey("jwk", sender.publicKey)
  const recipientPublicJwk = await crypto.subtle.exportKey("jwk", recipient.publicKey)

  const payload = await encryptE2EEDM({
    plaintext: "test aad tamper",
    senderApId: "https://example.com/users/alice",
    senderKid: "e2ee-alice",
    senderPrivateKey: sender.privateKey,
    recipientApId: "https://example.net/users/bob",
    recipientKid: "e2ee-bob",
    recipientJwk: recipientPublicJwk,
  })

  payload.aad.sender_kid = "e2ee-alice-rotated"

  await assert.rejects(() =>
    decryptE2EEDM({
      payload,
      myPrivateKey: recipient.privateKey,
      otherPublicJwk: senderPublicJwk,
    })
  )
})
