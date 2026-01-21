# frozen_string_literal: true

# The official Mastodon docker image installs production-only gems.
# When running Mastodon in development mode (needed for HTTP in fedbox),
# some initializers reference LetterOpenerWeb, which isn't present.
#
# This stub keeps Mastodon bootable for federation smoke tests.
module LetterOpenerWeb
  # Used in config/routes.rb in development mode:
  #   mount LetterOpenerWeb::Engine, at: "/letter_opener"
  # For fedbox we don't need the UI, but routes need this constant to exist.
  class Engine
    def self.call(_env)
      [404, {"content-type" => "text/plain"}, ["Not Found"]]
    end
  end

  class LettersController
    def self.content_security_policy(&_block)
    end

    def self.after_action(&_block)
    end
  end
end
