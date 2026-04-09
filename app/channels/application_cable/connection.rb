module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
      logger.info "ActionCable: User #{current_user.email} connected"
    end

    def disconnect
      logger.info "ActionCable: User #{current_user&.email} disconnected"
    end

    private

    def find_verified_user
      # Use Devise's current_user method to authenticate
      # This relies on the same session/cookie authentication as the web app
      if (verified_user = env['warden']&.user)
        verified_user
      else
        reject_unauthorized_connection
      end
    end
  end
end
