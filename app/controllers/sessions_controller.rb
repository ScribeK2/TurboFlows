class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: :heartbeat

  def heartbeat
    if current_user
      head :ok
    else
      head :unauthorized
    end
  end
end
