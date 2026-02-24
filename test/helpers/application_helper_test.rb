require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "display_workflow_description returns description text" do
    workflow = Workflow.new(description: "Test description")
    assert_equal "Test description", display_workflow_description(workflow)
  end

  test "display_workflow_description returns fallback for blank" do
    workflow = Workflow.new(description: nil)
    assert_equal "No description", display_workflow_description(workflow)
  end
end
