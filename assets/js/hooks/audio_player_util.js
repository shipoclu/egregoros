/**
 * Shared audio player initialization logic
 * Used by both the AudioPlayer hook and dynamic audio elements in MediaViewer
 */
import {parseID3, revokeArtwork} from "./id3_parser"

const playIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-6">
  <path d="M8 5v14l11-7z"/>
</svg>`

const musicIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-8">
  <path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"/>
</svg>`

const pauseIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-6">
  <path d="M6 4h4v16H6zM14 4h4v16h-4z"/>
</svg>`

function formatTime(seconds) {
  if (!Number.isFinite(seconds)) return "0:00"
  const mins = Math.floor(seconds / 60)
  const secs = Math.floor(seconds % 60)
  return `${mins}:${secs.toString().padStart(2, "0")}`
}

function getThemeColors() {
  const style = getComputedStyle(document.documentElement)
  return {
    bgColor: style.getPropertyValue("--bg-subtle").trim() || "#f5f5f5",
    barColor: style.getPropertyValue("--text-primary").trim() || "#000000",
    mutedColor: style.getPropertyValue("--text-muted").trim() || "#888888",
  }
}

function drawIdleVisualization(ctx, width, height) {
  const barCount = 24
  const barWidth = (width / barCount) - 2
  const gap = 2
  const {bgColor, mutedColor} = getThemeColors()

  ctx.fillStyle = bgColor
  ctx.fillRect(0, 0, width, height)

  for (let i = 0; i < barCount; i++) {
    const barHeight = 4 + Math.sin(i * 0.5) * 2
    const x = i * (barWidth + gap)
    const y = height - barHeight

    ctx.fillStyle = mutedColor
    ctx.fillRect(x, y, barWidth, barHeight)
  }
}

function drawFrequencyVisualization(ctx, width, height, analyser) {
  const bufferLength = analyser.frequencyBinCount
  const dataArray = new Uint8Array(bufferLength)
  analyser.getByteFrequencyData(dataArray)

  const barCount = 24
  const barWidth = (width / barCount) - 2
  const gap = 2
  const {bgColor, barColor} = getThemeColors()

  ctx.fillStyle = bgColor
  ctx.fillRect(0, 0, width, height)

  for (let i = 0; i < barCount; i++) {
    const dataIndex = Math.floor(i * bufferLength / barCount)
    const value = dataArray[dataIndex]
    const barHeight = Math.max(4, (value / 255) * height * 0.9)

    const x = i * (barWidth + gap)
    const y = height - barHeight

    ctx.fillStyle = barColor
    ctx.fillRect(x, y, barWidth, barHeight)
  }
}

/**
 * Initialize a custom audio player on a container element
 * @param {HTMLElement} container - Element containing an <audio> element
 */
export function initAudioPlayer(container) {
  const audio = container.querySelector("audio")
  if (!audio) return

  // Check if already initialized
  if (container.querySelector(".audio-player")) return

  // Hide native audio controls
  audio.removeAttribute("controls")
  audio.style.display = "none"

  // State
  let isPlaying = false
  let audioContext = null
  let analyser = null
  let source = null
  let animationId = null
  let connected = false
  let artworkUrl = null

  // Create player container
  const player = document.createElement("div")
  player.className = "audio-player"
  player.setAttribute("role", "group")
  player.setAttribute("aria-label", "Audio player")

  // Create header with metadata
  const header = document.createElement("div")
  header.className = "audio-player-header"

  // Artwork container
  const artworkContainer = document.createElement("div")
  artworkContainer.className = "audio-player-artwork"
  artworkContainer.innerHTML = musicIcon

  // Metadata container
  const metadataContainer = document.createElement("div")
  metadataContainer.className = "audio-player-metadata"

  const titleEl = document.createElement("div")
  titleEl.className = "audio-player-title"
  titleEl.textContent = "Audio"

  const artistEl = document.createElement("div")
  artistEl.className = "audio-player-artist"
  artistEl.textContent = ""

  metadataContainer.appendChild(titleEl)
  metadataContainer.appendChild(artistEl)

  // Visualizer canvas (in header)
  const canvas = document.createElement("canvas")
  canvas.className = "audio-player-visualizer"
  canvas.width = 120
  canvas.height = 48
  const ctx = canvas.getContext("2d")

  header.appendChild(artworkContainer)
  header.appendChild(metadataContainer)
  header.appendChild(canvas)

  // Create controls container
  const controls = document.createElement("div")
  controls.className = "audio-player-controls"

  // Play/pause button
  const playBtn = document.createElement("button")
  playBtn.type = "button"
  playBtn.className = "audio-player-play"
  playBtn.setAttribute("aria-label", "Play")
  playBtn.innerHTML = playIcon

  // Progress container
  const progressContainer = document.createElement("div")
  progressContainer.className = "audio-player-progress-container"

  // Time display
  const timeDisplay = document.createElement("div")
  timeDisplay.className = "audio-player-time"
  timeDisplay.textContent = "0:00"

  // Progress bar
  const progressBar = document.createElement("div")
  progressBar.className = "audio-player-progress"
  progressBar.setAttribute("role", "slider")
  progressBar.setAttribute("aria-label", "Seek")
  progressBar.setAttribute("aria-valuemin", "0")
  progressBar.setAttribute("aria-valuemax", "100")
  progressBar.setAttribute("aria-valuenow", "0")
  progressBar.tabIndex = 0

  const progressFill = document.createElement("div")
  progressFill.className = "audio-player-progress-fill"
  progressBar.appendChild(progressFill)

  // Duration display
  const durationDisplay = document.createElement("div")
  durationDisplay.className = "audio-player-time"
  durationDisplay.textContent = "0:00"

  progressContainer.appendChild(timeDisplay)
  progressContainer.appendChild(progressBar)
  progressContainer.appendChild(durationDisplay)

  controls.appendChild(playBtn)
  controls.appendChild(progressContainer)

  player.appendChild(header)
  player.appendChild(controls)

  container.appendChild(player)

  // Draw initial idle state
  drawIdleVisualization(ctx, canvas.width, canvas.height)

  // Load metadata from audio file
  const audioSrc = audio.querySelector("source")?.src || audio.src
  if (audioSrc) {
    parseID3(audioSrc).then(metadata => {
      if (metadata.title) {
        titleEl.textContent = metadata.title
      }
      if (metadata.artist) {
        artistEl.textContent = metadata.artist
        artistEl.style.display = "block"
      }
      if (metadata.album && !metadata.artist) {
        artistEl.textContent = metadata.album
        artistEl.style.display = "block"
      } else if (metadata.album && metadata.artist) {
        artistEl.textContent = `${metadata.artist} — ${metadata.album}`
      }
      if (metadata.artwork) {
        artworkUrl = metadata.artwork
        const img = document.createElement("img")
        img.src = metadata.artwork
        img.alt = metadata.title || "Album artwork"
        img.className = "audio-player-artwork-img"
        artworkContainer.innerHTML = ""
        artworkContainer.appendChild(img)
      }
    })
  }

  // Functions
  function initAudioContext() {
    if (connected) return

    try {
      audioContext = new (window.AudioContext || window.webkitAudioContext)()
      analyser = audioContext.createAnalyser()
      analyser.fftSize = 64
      source = audioContext.createMediaElementSource(audio)
      source.connect(analyser)
      analyser.connect(audioContext.destination)
      connected = true
    } catch (e) {
      console.warn("Audio visualization not available:", e)
    }
  }

  function startVisualization() {
    if (!analyser) {
      drawIdleVisualization(ctx, canvas.width, canvas.height)
      return
    }

    const draw = () => {
      if (!isPlaying) return
      animationId = requestAnimationFrame(draw)
      drawFrequencyVisualization(ctx, canvas.width, canvas.height, analyser)
    }

    draw()
  }

  function stopVisualization() {
    if (animationId) {
      cancelAnimationFrame(animationId)
      animationId = null
    }
    drawIdleVisualization(ctx, canvas.width, canvas.height)
  }

  function updateProgress() {
    const percent = (audio.currentTime / audio.duration) * 100 || 0
    progressFill.style.width = `${percent}%`
    progressBar.setAttribute("aria-valuenow", Math.round(percent))
    timeDisplay.textContent = formatTime(audio.currentTime)
  }

  function seek(e) {
    const rect = progressBar.getBoundingClientRect()
    const percent = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    audio.currentTime = percent * audio.duration
  }

  function togglePlay() {
    if (isPlaying) {
      audio.pause()
    } else {
      initAudioContext()
      audio.play().catch(() => {})
    }
  }

  // Event listeners
  playBtn.addEventListener("click", togglePlay)

  audio.addEventListener("loadedmetadata", () => {
    durationDisplay.textContent = formatTime(audio.duration)
  })

  audio.addEventListener("timeupdate", updateProgress)

  audio.addEventListener("ended", () => {
    isPlaying = false
    playBtn.innerHTML = playIcon
    playBtn.setAttribute("aria-label", "Play")
    stopVisualization()
  })

  audio.addEventListener("play", () => {
    isPlaying = true
    playBtn.innerHTML = pauseIcon
    playBtn.setAttribute("aria-label", "Pause")
    startVisualization()
  })

  audio.addEventListener("pause", () => {
    isPlaying = false
    playBtn.innerHTML = playIcon
    playBtn.setAttribute("aria-label", "Play")
    stopVisualization()
  })

  progressBar.addEventListener("click", seek)

  progressBar.addEventListener("keydown", e => {
    const step = 5
    if (e.key === "ArrowRight") {
      e.preventDefault()
      audio.currentTime = Math.min(audio.duration, audio.currentTime + step)
    } else if (e.key === "ArrowLeft") {
      e.preventDefault()
      audio.currentTime = Math.max(0, audio.currentTime - step)
    }
  })

  // Drag seeking
  let dragging = false
  progressBar.addEventListener("mousedown", e => {
    dragging = true
    seek(e)
  })

  const onMouseMove = e => {
    if (dragging) seek(e)
  }

  const onMouseUp = () => {
    dragging = false
  }

  document.addEventListener("mousemove", onMouseMove)
  document.addEventListener("mouseup", onMouseUp)

  // Return cleanup function
  return () => {
    if (animationId) cancelAnimationFrame(animationId)
    if (audioContext && audioContext.state !== "closed") {
      audioContext.close().catch(() => {})
    }
    if (artworkUrl) revokeArtwork(artworkUrl)
    document.removeEventListener("mousemove", onMouseMove)
    document.removeEventListener("mouseup", onMouseUp)
  }
}
