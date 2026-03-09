require "test_helper"

class Steps::SubFlowTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "sf-test@example.com", password: "password123!", password_confirmation: "password123!")
    @workflow = Workflow.create!(title: "Parent", user: @user)
    @target = Workflow.create!(title: "Child", user: @user, status: "published")
  end

  test "sub_flow step references target workflow" do
    step = Steps::SubFlow.create!(workflow: @workflow, position: 0, title: "SF1", sub_flow_workflow_id: @target.id)
    assert_equal @target, step.target_workflow
  end

  test "sub_flow step requires target_workflow" do
    step = Steps::SubFlow.new(workflow: @workflow, position: 0, title: "SF1")
    assert_not step.valid?
  end
end
