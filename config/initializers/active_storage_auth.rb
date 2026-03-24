# Configure Active Storage to work with authentication
# Active Storage controllers inherit from ActiveStorage::BaseController
# which doesn't inherit from ApplicationController, so we need to add
# authentication here

Rails.application.config.to_prepare do
  ActiveStorage::BaseController.include Devise::Controllers::Helpers if defined?(Devise)
  ActiveStorage::BaseController.before_action :authenticate_user!
end
