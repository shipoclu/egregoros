/**
 * Lightweight ID3v2 tag parser
 * Extracts title, artist, album, and cover art from MP3 files
 */

const TEXT_FRAMES = {
  TIT2: "title",
  TPE1: "artist",
  TALB: "album",
  TPE2: "albumArtist",
  TYER: "year",
  TDRC: "year",
}

function decodeString(bytes, encoding) {
  if (encoding === 0) {
    // ISO-8859-1
    let str = ""
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] === 0) break
      str += String.fromCharCode(bytes[i])
    }
    return str
  } else if (encoding === 1) {
    // UTF-16 with BOM
    const bom = (bytes[0] << 8) | bytes[1]
    const isLE = bom === 0xfffe
    let str = ""
    for (let i = 2; i < bytes.length - 1; i += 2) {
      const code = isLE ? (bytes[i + 1] << 8) | bytes[i] : (bytes[i] << 8) | bytes[i + 1]
      if (code === 0) break
      str += String.fromCharCode(code)
    }
    return str
  } else if (encoding === 2) {
    // UTF-16 BE without BOM
    let str = ""
    for (let i = 0; i < bytes.length - 1; i += 2) {
      const code = (bytes[i] << 8) | bytes[i + 1]
      if (code === 0) break
      str += String.fromCharCode(code)
    }
    return str
  } else if (encoding === 3) {
    // UTF-8
    const decoder = new TextDecoder("utf-8")
    const nullIdx = bytes.indexOf(0)
    return decoder.decode(nullIdx >= 0 ? bytes.slice(0, nullIdx) : bytes)
  }
  return ""
}

function parseTextFrame(data) {
  const encoding = data[0]
  return decodeString(data.slice(1), encoding)
}

function parsePictureFrame(data) {
  const encoding = data[0]
  let offset = 1

  // Find end of MIME type (null-terminated)
  let mimeEnd = offset
  while (mimeEnd < data.length && data[mimeEnd] !== 0) mimeEnd++
  const mimeType = decodeString(data.slice(offset, mimeEnd), 0)
  offset = mimeEnd + 1

  // Picture type (1 byte)
  const pictureType = data[offset]
  offset++

  // Description (encoding-dependent null-terminated)
  if (encoding === 1 || encoding === 2) {
    // UTF-16: look for double null
    while (offset < data.length - 1) {
      if (data[offset] === 0 && data[offset + 1] === 0) {
        offset += 2
        break
      }
      offset++
    }
  } else {
    // Single byte encoding: single null
    while (offset < data.length && data[offset] !== 0) offset++
    offset++
  }

  // Rest is image data
  const imageData = data.slice(offset)
  if (imageData.length === 0) return null

  const blob = new Blob([imageData], {type: mimeType || "image/jpeg"})
  return URL.createObjectURL(blob)
}

function syncsafeToInt(bytes) {
  return ((bytes[0] & 0x7f) << 21) | ((bytes[1] & 0x7f) << 14) | ((bytes[2] & 0x7f) << 7) | (bytes[3] & 0x7f)
}

function readFrameSize(bytes, version) {
  if (version === 4) {
    return syncsafeToInt(bytes)
  }
  // ID3v2.3 uses regular integers
  return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
}

/**
 * Parse ID3v2 tags from audio file
 * @param {string} url - URL of the audio file
 * @returns {Promise<{title?: string, artist?: string, album?: string, artwork?: string}>}
 */
export async function parseID3(url) {
  const result = {}

  try {
    // Fetch first 128KB which should contain ID3 header and common tags
    const response = await fetch(url, {
      headers: {Range: "bytes=0-131072"},
    })

    if (!response.ok) return result

    const buffer = await response.arrayBuffer()
    const data = new Uint8Array(buffer)

    // Check for ID3v2 header
    if (data[0] !== 0x49 || data[1] !== 0x44 || data[2] !== 0x33) {
      // No ID3v2 tag
      return result
    }

    const version = data[3]
    const flags = data[5]
    const tagSize = syncsafeToInt(data.slice(6, 10))

    // Skip extended header if present
    let offset = 10
    if (flags & 0x40) {
      const extSize = syncsafeToInt(data.slice(10, 14))
      offset += extSize
    }

    const tagEnd = Math.min(10 + tagSize, data.length)

    // Parse frames
    while (offset < tagEnd - 10) {
      const frameId = String.fromCharCode(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])

      // Check for padding (all zeros)
      if (frameId === "\x00\x00\x00\x00") break

      const frameSize = readFrameSize(data.slice(offset + 4, offset + 8), version)
      const frameFlags = (data[offset + 8] << 8) | data[offset + 9]
      offset += 10

      if (frameSize <= 0 || offset + frameSize > tagEnd) break

      const frameData = data.slice(offset, offset + frameSize)

      // Handle text frames
      if (TEXT_FRAMES[frameId]) {
        const value = parseTextFrame(frameData)
        if (value) result[TEXT_FRAMES[frameId]] = value
      }

      // Handle picture frame (APIC)
      if (frameId === "APIC" && !result.artwork) {
        const artworkUrl = parsePictureFrame(frameData)
        if (artworkUrl) result.artwork = artworkUrl
      }

      offset += frameSize
    }
  } catch (e) {
    console.warn("ID3 parsing failed:", e)
  }

  return result
}

/**
 * Clean up artwork blob URL when no longer needed
 */
export function revokeArtwork(url) {
  if (url && url.startsWith("blob:")) {
    URL.revokeObjectURL(url)
  }
}
