import {lockScroll, unlockScroll} from "./scroll_lock"

class ImageCropper {
  constructor(section) {
    this.section = section
    this.modal = document.getElementById("cropper-modal")
    this.imageEl = this.modal?.querySelector("[data-role='cropper-image']")
    this.cropBox = this.modal?.querySelector("[data-role='crop-box']")
    this.cancelBtn = this.modal?.querySelector("[data-role='cropper-cancel']")
    this.confirmBtn = this.modal?.querySelector("[data-role='cropper-confirm']")

    this.currentInput = null
    this.aspectRatio = 1
    this.imageData = null
    this.cropData = {x: 0, y: 0, width: 0, height: 0}
    this.imgBounds = null
    this.dragState = null

    this.avatarInput = section.querySelector("input[name='profile[avatar]']")
    this.bannerInput = section.querySelector("input[name='profile[banner]']")

    this.bindEvents()
  }

  bindEvents() {
    if (this.avatarInput) {
      this.avatarInput.addEventListener("change", e => this.handleFileSelect(e.target, 1))
    }

    if (this.bannerInput) {
      this.bannerInput.addEventListener("change", e => this.handleFileSelect(e.target, 3))
    }

    if (this.cancelBtn) {
      this.cancelBtn.addEventListener("click", () => this.close(true))
    }

    if (this.confirmBtn) {
      this.confirmBtn.addEventListener("click", () => this.applyCrop())
    }

    this.onMouseDown = e => this.startDrag(e)
    this.onMouseMove = e => this.drag(e)
    this.onMouseUp = () => this.endDrag()
    this.onTouchStart = e => this.startDrag(e)
    this.onTouchMove = e => this.drag(e)
    this.onTouchEnd = () => this.endDrag()

    window.addEventListener("keydown", e => {
      if (e.key === "Escape" && this.isOpen()) {
        this.close(true)
      }
    })
  }

  isOpen() {
    return this.modal && !this.modal.classList.contains("hidden")
  }

  handleFileSelect(input, aspectRatio) {
    const file = input.files?.[0]
    if (!file || !file.type.startsWith("image/")) return

    this.currentInput = input
    this.aspectRatio = aspectRatio

    const reader = new FileReader()
    reader.onload = e => {
      const img = new Image()
      img.onload = () => {
        this.imageData = {
          src: e.target.result,
          naturalWidth: img.naturalWidth,
          naturalHeight: img.naturalHeight,
        }
        this.open()
      }
      img.src = e.target.result
    }
    reader.readAsDataURL(file)
  }

  open() {
    if (!this.modal || !this.imageEl || !this.imageData) return

    lockScroll()
    this.imageEl.src = this.imageData.src
    this.modal.classList.remove("hidden")

    this.imageEl.onload = () => {
      this.initCropBox()
      this.setupDragListeners()
    }

    if (this.imageEl.complete) {
      this.initCropBox()
      this.setupDragListeners()
    }
  }

  close(clearInput = true) {
    if (!this.modal) return

    unlockScroll()
    this.modal.classList.add("hidden")
    this.cleanupDragListeners()

    if (clearInput && this.currentInput) {
      this.currentInput.value = ""
    }

    this.currentInput = null
    this.imageData = null
  }

  initCropBox() {
    if (!this.imageEl || !this.cropBox) return

    const container = this.imageEl.parentElement
    const containerRect = container.getBoundingClientRect()
    const imgRect = this.imageEl.getBoundingClientRect()

    const imgOffsetX = imgRect.left - containerRect.left
    const imgOffsetY = imgRect.top - containerRect.top
    const imgWidth = imgRect.width
    const imgHeight = imgRect.height

    let cropWidth, cropHeight

    if (imgWidth / imgHeight > this.aspectRatio) {
      cropHeight = imgHeight * 0.8
      cropWidth = cropHeight * this.aspectRatio
    } else {
      cropWidth = imgWidth * 0.8
      cropHeight = cropWidth / this.aspectRatio
    }

    const cropX = imgOffsetX + (imgWidth - cropWidth) / 2
    const cropY = imgOffsetY + (imgHeight - cropHeight) / 2

    this.cropData = {x: cropX, y: cropY, width: cropWidth, height: cropHeight}
    this.imgBounds = {x: imgOffsetX, y: imgOffsetY, width: imgWidth, height: imgHeight}

    this.updateCropBoxPosition()
  }

  updateCropBoxPosition() {
    if (!this.cropBox) return

    this.cropBox.style.left = `${this.cropData.x}px`
    this.cropBox.style.top = `${this.cropData.y}px`
    this.cropBox.style.width = `${this.cropData.width}px`
    this.cropBox.style.height = `${this.cropData.height}px`
  }

  setupDragListeners() {
    const container = this.imageEl?.parentElement
    if (!container) return

    container.addEventListener("mousedown", this.onMouseDown)
    window.addEventListener("mousemove", this.onMouseMove)
    window.addEventListener("mouseup", this.onMouseUp)
    container.addEventListener("touchstart", this.onTouchStart, {passive: false})
    window.addEventListener("touchmove", this.onTouchMove, {passive: false})
    window.addEventListener("touchend", this.onTouchEnd)
  }

  cleanupDragListeners() {
    const container = this.imageEl?.parentElement
    if (container) {
      container.removeEventListener("mousedown", this.onMouseDown)
      container.removeEventListener("touchstart", this.onTouchStart)
    }
    window.removeEventListener("mousemove", this.onMouseMove)
    window.removeEventListener("mouseup", this.onMouseUp)
    window.removeEventListener("touchmove", this.onTouchMove)
    window.removeEventListener("touchend", this.onTouchEnd)
  }

  getEventPos(e) {
    const container = this.imageEl?.parentElement
    if (!container) return {x: 0, y: 0}

    const rect = container.getBoundingClientRect()
    const clientX = e.touches ? e.touches[0].clientX : e.clientX
    const clientY = e.touches ? e.touches[0].clientY : e.clientY

    return {x: clientX - rect.left, y: clientY - rect.top}
  }

  getHandle(pos) {
    const {x, y, width, height} = this.cropData
    const handleSize = 20

    const inCrop = pos.x >= x && pos.x <= x + width && pos.y >= y && pos.y <= y + height

    if (!inCrop) return null

    const nearLeft = pos.x < x + handleSize
    const nearRight = pos.x > x + width - handleSize
    const nearTop = pos.y < y + handleSize
    const nearBottom = pos.y > y + height - handleSize

    if (nearTop && nearLeft) return "nw"
    if (nearTop && nearRight) return "ne"
    if (nearBottom && nearLeft) return "sw"
    if (nearBottom && nearRight) return "se"
    if (nearTop) return "n"
    if (nearBottom) return "s"
    if (nearLeft) return "w"
    if (nearRight) return "e"

    return "move"
  }

  startDrag(e) {
    const pos = this.getEventPos(e)
    const handle = this.getHandle(pos)

    if (!handle) return

    e.preventDefault()

    this.dragState = {
      handle,
      startX: pos.x,
      startY: pos.y,
      startCrop: {...this.cropData},
    }
  }

  drag(e) {
    if (!this.dragState) return

    e.preventDefault()

    const pos = this.getEventPos(e)
    const dx = pos.x - this.dragState.startX
    const dy = pos.y - this.dragState.startY
    const {handle, startCrop} = this.dragState

    let newCrop = {...startCrop}

    if (handle === "move") {
      newCrop.x = startCrop.x + dx
      newCrop.y = startCrop.y + dy
    } else {
      newCrop = this.resizeCrop(handle, dx, dy, startCrop)
    }

    this.cropData = this.constrainCrop(newCrop)
    this.updateCropBoxPosition()
  }

  resizeCrop(handle, dx, dy, startCrop) {
    let {x, y, width, height} = startCrop
    const minSize = 50

    if (handle.includes("e")) {
      width = Math.max(minSize, startCrop.width + dx)
      height = width / this.aspectRatio
    } else if (handle.includes("w")) {
      const newWidth = Math.max(minSize, startCrop.width - dx)
      const newHeight = newWidth / this.aspectRatio
      x = startCrop.x + startCrop.width - newWidth
      width = newWidth
      height = newHeight
    }

    if (handle.includes("s") && !handle.includes("e") && !handle.includes("w")) {
      height = Math.max(minSize, startCrop.height + dy)
      width = height * this.aspectRatio
    } else if (handle.includes("n") && !handle.includes("e") && !handle.includes("w")) {
      const newHeight = Math.max(minSize, startCrop.height - dy)
      const newWidth = newHeight * this.aspectRatio
      y = startCrop.y + startCrop.height - newHeight
      width = newWidth
      height = newHeight
    }

    if (handle === "se") {
      const avgDelta = (dx + dy / this.aspectRatio) / 2
      width = Math.max(minSize, startCrop.width + avgDelta)
      height = width / this.aspectRatio
    } else if (handle === "sw") {
      const avgDelta = (-dx + dy / this.aspectRatio) / 2
      const newWidth = Math.max(minSize, startCrop.width + avgDelta)
      const newHeight = newWidth / this.aspectRatio
      x = startCrop.x + startCrop.width - newWidth
      width = newWidth
      height = newHeight
    } else if (handle === "ne") {
      const avgDelta = (dx - dy / this.aspectRatio) / 2
      const newWidth = Math.max(minSize, startCrop.width + avgDelta)
      const newHeight = newWidth / this.aspectRatio
      y = startCrop.y + startCrop.height - newHeight
      width = newWidth
      height = newHeight
    } else if (handle === "nw") {
      const avgDelta = (-dx - dy / this.aspectRatio) / 2
      const newWidth = Math.max(minSize, startCrop.width + avgDelta)
      const newHeight = newWidth / this.aspectRatio
      x = startCrop.x + startCrop.width - newWidth
      y = startCrop.y + startCrop.height - newHeight
      width = newWidth
      height = newHeight
    }

    return {x, y, width, height}
  }

  constrainCrop(crop) {
    const bounds = this.imgBounds
    if (!bounds) return crop

    let {x, y, width, height} = crop

    if (width > bounds.width) {
      width = bounds.width
      height = width / this.aspectRatio
    }

    if (height > bounds.height) {
      height = bounds.height
      width = height * this.aspectRatio
    }

    if (x < bounds.x) x = bounds.x
    if (y < bounds.y) y = bounds.y
    if (x + width > bounds.x + bounds.width) x = bounds.x + bounds.width - width
    if (y + height > bounds.y + bounds.height) y = bounds.y + bounds.height - height

    return {x, y, width, height}
  }

  endDrag() {
    this.dragState = null
  }

  async applyCrop() {
    if (!this.imageData || !this.currentInput || !this.imgBounds) return

    const scaleX = this.imageData.naturalWidth / this.imgBounds.width
    const scaleY = this.imageData.naturalHeight / this.imgBounds.height

    const srcX = (this.cropData.x - this.imgBounds.x) * scaleX
    const srcY = (this.cropData.y - this.imgBounds.y) * scaleY
    const srcWidth = this.cropData.width * scaleX
    const srcHeight = this.cropData.height * scaleY

    const canvas = document.createElement("canvas")
    canvas.width = srcWidth
    canvas.height = srcHeight

    const ctx = canvas.getContext("2d")
    const img = new Image()

    img.onload = () => {
      ctx.drawImage(img, srcX, srcY, srcWidth, srcHeight, 0, 0, srcWidth, srcHeight)

      canvas.toBlob(
        blob => {
          if (!blob) return

          const originalFile = this.currentInput.files[0]
          const fileName = originalFile?.name || "cropped.jpg"
          const file = new File([blob], fileName, {type: "image/jpeg"})

          const dataTransfer = new DataTransfer()
          dataTransfer.items.add(file)
          this.currentInput.files = dataTransfer.files

          this.close(false)
        },
        "image/jpeg",
        0.9
      )
    }

    img.src = this.imageData.src
  }
}

export const initImageCropper = () => {
  const section = document.querySelector("[data-role='image-cropper-section']")
  if (section && !section.dataset.cropperInitialized) {
    section.dataset.cropperInitialized = "true"
    new ImageCropper(section)
  }
}

export default ImageCropper
