ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/performance_helper"
require_relative "support/strict_document_normalizer"

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
    end
    login_as(resource, scope: scope)
  end
end

# Global exists in every real database (the Stage 4a migration made it) but not
# in a test database, and nothing creates it on read. A test that needs it asks.
module GlobalGroupHelper
  def global_group
    Group.global.first || Group.create!(name: Group::GLOBAL_NAME)
  end

  # For a test that means "everyone can see this" — what is_public: true meant.
  def file_in_global(workflow)
    GroupWorkflow.create!(group: global_group, workflow: workflow, is_primary: workflow.group_workflows.none?)
    workflow
  end
end

# Counts the SQL a block asks for, leaving out schema lookups. Compare a page at
# two sizes: equal counts mean nothing is queried per row. Query-cache hits
# count: in a test the cache can survive between requests while the data is
# unchanged, so skipping them made the smaller page look like one query.
module QueryCountHelper
  def count_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end
end

ActiveSupport.on_load(:active_support_test_case) { include GlobalGroupHelper, QueryCountHelper }
