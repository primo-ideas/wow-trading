# This file is used by Rack-based servers to start the application.

require_relative "config/environment"

# Under a path of its own when it shares a domain with other sites: see deploy/README.md.
map Rails.application.config.relative_url_root.presence || "/" do
  run Rails.application
end
Rails.application.load_server
