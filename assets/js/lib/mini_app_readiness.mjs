export const createMiniAppReadiness = ({
  timeoutMs = 10_000,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  onTimeout,
} = {}) => {
  let timer = null
  let generation = 0
  let launchId = null

  const clear = () => {
    generation += 1
    if (timer !== null) clearTimer(timer)
    timer = null
    launchId = null
  }

  return {
    loading: nextLaunchId => {
      clear()
      launchId = nextLaunchId
      const currentGeneration = generation
      timer = setTimer(() => {
        if (currentGeneration !== generation || launchId !== nextLaunchId) return
        timer = null
        onTimeout?.(nextLaunchId)
      }, timeoutMs)
    },
    ready: readyLaunchId => {
      if (readyLaunchId === launchId) clear()
    },
    destroy: clear,
  }
}
