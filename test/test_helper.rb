ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/performance_helper"

class ActiveSupport::TestCase
  # Disable parallelization temporarily to avoid fixture issues
  # parallelize(workers: :number_of_processors)

  # Don't load fixtures by default - load them selectively in tests that need them
  # This avoids JSON fixture teardown issues in Rails 8.0
  # fixtures :all

  # Add more helper methods to be used by all tests here...
  include Devise::Test::IntegrationHelpers

  # Reset rack-attack cache between tests to prevent throttle bleed
  setup do
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!
  end
end

# Fix for Devise sign_in with dynamically created users
# Use :user scope directly since we know it's configured in routes
ActionDispatch::IntegrationTest.class_eval do
  def sign_in(resource_or_scope, resource = nil)
    if resource.nil?
      resource = resource_or_scope
      # Use :user scope directly for User model
      scope = resource.is_a?(User) ? :user : Devise::Mapping.find_scope!(resource.class)
    else
      scope = resource_or_scope
      resource = resource
    end
    login_as(resource, scope: scope)
  end
end
