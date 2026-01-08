/**
 * Custom brutalist audio player with frequency visualization
 * Phoenix LiveView hook wrapper
 */
import {initAudioPlayer} from "./audio_player_util"

const AudioPlayer = {
  mounted() {
    this.cleanup = initAudioPlayer(this.el)
  },

  destroyed() {
    if (this.cleanup) this.cleanup()
  },
}

export default AudioPlayer
