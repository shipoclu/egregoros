/**
 * Shared video player initialization logic
 * Custom brutalist video player with controls and fullscreen support
 */

const playIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M8 5v14l11-7z"/>
</svg>`

const pauseIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M6 4h4v16H6zM14 4h4v16h-4z"/>
</svg>`

const fullscreenIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/>
</svg>`

const exitFullscreenIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M5 16h3v3h2v-5H5v2zm3-8H5v2h5V5H8v3zm6 11h2v-3h3v-2h-5v5zm2-11V5h-2v5h5V8h-3z"/>
</svg>`

const volumeIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/>
</svg>`

const volumeMuteIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/>
</svg>`

const crtIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M21 3H3c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h5v2h8v-2h5c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 14H3V5h18v12z"/>
</svg>`

const cleanIcon = `<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
  <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H5V5h14v14z"/>
</svg>`

const PLAYBACK_SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

// Inject SVG filter for chromatic aberration (only once)
function ensureCRTFilter() {
  if (document.getElementById("crt-svg-filters")) return

  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
  svg.id = "crt-svg-filters"
  svg.setAttribute("width", "0")
  svg.setAttribute("height", "0")
  svg.style.position = "absolute"
  svg.style.pointerEvents = "none"

  svg.innerHTML = `
    <defs>
      <filter id="crt-aberration" x="-10%" y="-10%" width="120%" height="120%">
        <!-- Red channel offset (stronger shift) -->
        <feOffset in="SourceGraphic" dx="-3" dy="0" result="red-shifted">
        </feOffset>
        <feColorMatrix in="red-shifted" type="matrix" result="red"
          values="1 0 0 0 0
                  0 0 0 0 0
                  0 0 0 0 0
                  0 0 0 1 0"/>

        <!-- Blue channel offset (stronger shift) -->
        <feOffset in="SourceGraphic" dx="3" dy="0" result="blue-shifted">
        </feOffset>
        <feColorMatrix in="blue-shifted" type="matrix" result="blue"
          values="0 0 0 0 0
                  0 0 0 0 0
                  0 0 1 0 0
                  0 0 0 1 0"/>

        <!-- Green channel (no offset) -->
        <feColorMatrix in="SourceGraphic" type="matrix" result="green"
          values="0 0 0 0 0
                  0 1 0 0 0
                  0 0 0 0 0
                  0 0 0 1 0"/>

        <!-- Blend channels together -->
        <feBlend mode="screen" in="red" in2="green" result="rg"/>
        <feBlend mode="screen" in="rg" in2="blue" result="rgb"/>
      </filter>
    </defs>
  `

  document.body.appendChild(svg)
}

function formatSpeed(speed) {
  return speed === 1 ? "1x" : `${speed}x`
}

function formatTime(seconds) {
  if (!Number.isFinite(seconds)) return "0:00"
  const mins = Math.floor(seconds / 60)
  const secs = Math.floor(seconds % 60)
  return `${mins}:${secs.toString().padStart(2, "0")}`
}

/**
 * Initialize a custom video player on a container element
 * @param {HTMLElement} container - Element containing a <video> element
 */
export function initVideoPlayer(container) {
  const video = container.querySelector("video")
  if (!video) return

  // Check if already initialized
  if (container.querySelector(".video-player")) return

  // Inject CRT filter SVG if needed
  ensureCRTFilter()

  // Hide native video controls
  video.removeAttribute("controls")
  video.classList.add("video-player-video")

  // State
  let isPlaying = false
  let isFullscreen = false
  let isMuted = video.muted
  let controlsTimeout = null
  let controlsVisible = true

  // Create player wrapper
  const player = document.createElement("div")
  player.className = "video-player"
  player.setAttribute("role", "group")
  player.setAttribute("aria-label", "Video player")

  // Video container (for positioning)
  const videoContainer = document.createElement("div")
  videoContainer.className = "video-player-container"

  // Move video into container
  video.parentNode.insertBefore(player, video)
  videoContainer.appendChild(video)
  player.appendChild(videoContainer)

  // Click overlay for play/pause
  const clickOverlay = document.createElement("div")
  clickOverlay.className = "video-player-click-overlay"
  videoContainer.appendChild(clickOverlay)

  // Controls bar
  const controls = document.createElement("div")
  controls.className = "video-player-controls"

  // Play/pause button
  const playBtn = document.createElement("button")
  playBtn.type = "button"
  playBtn.className = "video-player-btn"
  playBtn.setAttribute("aria-label", "Play")
  playBtn.innerHTML = playIcon

  // Progress container
  const progressContainer = document.createElement("div")
  progressContainer.className = "video-player-progress-container"

  // Time display
  const timeDisplay = document.createElement("div")
  timeDisplay.className = "video-player-time"
  timeDisplay.textContent = "0:00"

  // Progress bar
  const progressBar = document.createElement("div")
  progressBar.className = "video-player-progress"
  progressBar.setAttribute("role", "slider")
  progressBar.setAttribute("aria-label", "Seek")
  progressBar.setAttribute("aria-valuemin", "0")
  progressBar.setAttribute("aria-valuemax", "100")
  progressBar.setAttribute("aria-valuenow", "0")
  progressBar.tabIndex = 0

  const progressFill = document.createElement("div")
  progressFill.className = "video-player-progress-fill"
  progressBar.appendChild(progressFill)

  // Duration display
  const durationDisplay = document.createElement("div")
  durationDisplay.className = "video-player-time"
  durationDisplay.textContent = "0:00"

  progressContainer.appendChild(timeDisplay)
  progressContainer.appendChild(progressBar)
  progressContainer.appendChild(durationDisplay)

  // Volume button
  const volumeBtn = document.createElement("button")
  volumeBtn.type = "button"
  volumeBtn.className = "video-player-btn"
  volumeBtn.setAttribute("aria-label", "Mute")
  volumeBtn.innerHTML = isMuted ? volumeMuteIcon : volumeIcon

  // Speed button
  const speedBtn = document.createElement("button")
  speedBtn.type = "button"
  speedBtn.className = "video-player-btn video-player-speed-btn"
  speedBtn.setAttribute("aria-label", "Playback speed")
  speedBtn.textContent = "1x"

  // CRT toggle button
  const crtBtn = document.createElement("button")
  crtBtn.type = "button"
  crtBtn.className = "video-player-btn"
  crtBtn.setAttribute("aria-label", "Toggle CRT effect")
  crtBtn.setAttribute("title", "Toggle CRT effect")
  crtBtn.innerHTML = crtIcon

  // Fullscreen button
  const fullscreenBtn = document.createElement("button")
  fullscreenBtn.type = "button"
  fullscreenBtn.className = "video-player-btn"
  fullscreenBtn.setAttribute("aria-label", "Fullscreen")
  fullscreenBtn.innerHTML = fullscreenIcon

  controls.appendChild(playBtn)
  controls.appendChild(progressContainer)
  controls.appendChild(volumeBtn)
  controls.appendChild(speedBtn)
  controls.appendChild(crtBtn)
  controls.appendChild(fullscreenBtn)

  videoContainer.appendChild(controls)

  // Functions
  function updateProgress() {
    const percent = (video.currentTime / video.duration) * 100 || 0
    progressFill.style.width = `${percent}%`
    progressBar.setAttribute("aria-valuenow", Math.round(percent))
    timeDisplay.textContent = formatTime(video.currentTime)
  }

  function seek(e) {
    const rect = progressBar.getBoundingClientRect()
    const percent = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    video.currentTime = percent * video.duration
  }

  function togglePlay() {
    if (isPlaying) {
      video.pause()
    } else {
      video.play().catch(() => {})
    }
  }

  function toggleMute() {
    video.muted = !video.muted
    isMuted = video.muted
    volumeBtn.innerHTML = isMuted ? volumeMuteIcon : volumeIcon
    volumeBtn.setAttribute("aria-label", isMuted ? "Unmute" : "Mute")
  }

  function toggleFullscreen() {
    if (!document.fullscreenElement) {
      player.requestFullscreen().catch(() => {})
    } else {
      document.exitFullscreen().catch(() => {})
    }
  }

  function cycleSpeed() {
    const currentSpeed = video.playbackRate
    const currentIndex = PLAYBACK_SPEEDS.indexOf(currentSpeed)
    const nextIndex = (currentIndex + 1) % PLAYBACK_SPEEDS.length
    const nextSpeed = PLAYBACK_SPEEDS[nextIndex]
    video.playbackRate = nextSpeed
    speedBtn.textContent = formatSpeed(nextSpeed)
  }

  function toggleCRT() {
    const isClean = player.classList.toggle("video-player-clean")
    crtBtn.innerHTML = isClean ? cleanIcon : crtIcon
    crtBtn.setAttribute("aria-label", isClean ? "Enable CRT effect" : "Disable CRT effect")
  }

  function showControls() {
    controlsVisible = true
    controls.classList.remove("video-player-controls-hidden")
    player.style.cursor = ""
  }

  function hideControls() {
    if (!isPlaying) return
    controlsVisible = false
    controls.classList.add("video-player-controls-hidden")
    player.style.cursor = "none"
  }

  function resetControlsTimeout() {
    showControls()
    if (controlsTimeout) clearTimeout(controlsTimeout)
    controlsTimeout = setTimeout(hideControls, 2500)
  }

  // Event listeners
  playBtn.addEventListener("click", e => {
    e.stopPropagation()
    togglePlay()
  })

  clickOverlay.addEventListener("click", togglePlay)

  video.addEventListener("loadedmetadata", () => {
    durationDisplay.textContent = formatTime(video.duration)
  })

  video.addEventListener("timeupdate", updateProgress)

  video.addEventListener("ended", () => {
    isPlaying = false
    playBtn.innerHTML = playIcon
    playBtn.setAttribute("aria-label", "Play")
    showControls()
  })

  video.addEventListener("play", () => {
    isPlaying = true
    playBtn.innerHTML = pauseIcon
    playBtn.setAttribute("aria-label", "Pause")
    resetControlsTimeout()
  })

  video.addEventListener("pause", () => {
    isPlaying = false
    playBtn.innerHTML = playIcon
    playBtn.setAttribute("aria-label", "Play")
    showControls()
    if (controlsTimeout) clearTimeout(controlsTimeout)
  })

  volumeBtn.addEventListener("click", e => {
    e.stopPropagation()
    toggleMute()
  })

  speedBtn.addEventListener("click", e => {
    e.stopPropagation()
    cycleSpeed()
  })

  crtBtn.addEventListener("click", e => {
    e.stopPropagation()
    toggleCRT()
  })

  fullscreenBtn.addEventListener("click", e => {
    e.stopPropagation()
    toggleFullscreen()
  })

  document.addEventListener("fullscreenchange", () => {
    isFullscreen = !!document.fullscreenElement
    fullscreenBtn.innerHTML = isFullscreen ? exitFullscreenIcon : fullscreenIcon
    fullscreenBtn.setAttribute("aria-label", isFullscreen ? "Exit fullscreen" : "Fullscreen")
  })

  progressBar.addEventListener("click", e => {
    e.stopPropagation()
    seek(e)
  })

  progressBar.addEventListener("keydown", e => {
    const step = 5
    if (e.key === "ArrowRight") {
      e.preventDefault()
      video.currentTime = Math.min(video.duration, video.currentTime + step)
    } else if (e.key === "ArrowLeft") {
      e.preventDefault()
      video.currentTime = Math.max(0, video.currentTime - step)
    }
  })

  // Drag seeking
  let dragging = false
  progressBar.addEventListener("mousedown", e => {
    e.stopPropagation()
    dragging = true
    seek(e)
  })

  const onMouseMove = e => {
    if (dragging) seek(e)
    resetControlsTimeout()
  }

  const onMouseUp = () => {
    dragging = false
  }

  document.addEventListener("mousemove", onMouseMove)
  document.addEventListener("mouseup", onMouseUp)

  // Show/hide controls on mouse movement
  player.addEventListener("mousemove", resetControlsTimeout)
  player.addEventListener("mouseleave", () => {
    if (isPlaying) hideControls()
  })

  // Keyboard controls
  player.addEventListener("keydown", e => {
    if (e.key === " " || e.key === "k") {
      e.preventDefault()
      togglePlay()
    } else if (e.key === "f") {
      e.preventDefault()
      toggleFullscreen()
    } else if (e.key === "m") {
      e.preventDefault()
      toggleMute()
    } else if (e.key === ">" || e.key === ".") {
      e.preventDefault()
      cycleSpeed()
    } else if (e.key === "<" || e.key === ",") {
      e.preventDefault()
      // Cycle backwards
      const currentSpeed = video.playbackRate
      const currentIndex = PLAYBACK_SPEEDS.indexOf(currentSpeed)
      const prevIndex = (currentIndex - 1 + PLAYBACK_SPEEDS.length) % PLAYBACK_SPEEDS.length
      const prevSpeed = PLAYBACK_SPEEDS[prevIndex]
      video.playbackRate = prevSpeed
      speedBtn.textContent = formatSpeed(prevSpeed)
    } else if (e.key === "c") {
      e.preventDefault()
      toggleCRT()
    }
  })

  // Make player focusable for keyboard controls
  player.tabIndex = 0

  // Return cleanup function
  return () => {
    if (controlsTimeout) clearTimeout(controlsTimeout)
    document.removeEventListener("mousemove", onMouseMove)
    document.removeEventListener("mouseup", onMouseUp)
  }
}
