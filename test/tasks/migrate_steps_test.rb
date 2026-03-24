require "test_helper"

class MigrateStepsTaskTest < ActiveSupport::TestCase
  test "JSONB-to-AR migration task is obsolete after steps column removal" do
    # The steps:migrate rake task converted JSONB workflow.steps to ActiveRecord
    # Step models. Since the JSONB `steps` column has been removed from the
    # workflows table, this migration is no longer applicable.
    # All steps are now created as AR records directly.
    assert_not Workflow.column_names.include?("steps"), "JSONB steps column should be removed"
  end
end
