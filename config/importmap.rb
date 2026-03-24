# Pin npm packages by running ./bin/importmap

# Application entry point
pin "application"

# Core Hotwire packages
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"

# ActionCable for real-time features
pin "@rails/actioncable", to: "actioncable.esm.js"

# Action Text (rich text editing with Lexxy)
pin "lexxy", to: "lexxy.js"

# Third-party libraries (vendored locally for reliability)
pin "sortablejs", to: "sortablejs.js"
pin "fuse.js", to: "fuse.js"
pin "spark-md5", to: "spark-md5.js"

# Pin all Stimulus controllers
pin_all_from "app/javascript/controllers", under: "controllers"

# Pin ActionCable channels
pin_all_from "app/javascript/channels", under: "channels"

# Pin services
pin_all_from "app/javascript/services", under: "services", to: "services"
