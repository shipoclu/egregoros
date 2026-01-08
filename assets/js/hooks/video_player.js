/**
 * Custom brutalist video player
 * Phoenix LiveView hook wrapper
 */
import {initVideoPlayer} from "./video_player_util"

const VideoPlayer = {
  mounted() {
    this.cleanup = initVideoPlayer(this.el)
  },

  destroyed() {
    if (this.cleanup) this.cleanup()
  },
}

export default VideoPlayer
