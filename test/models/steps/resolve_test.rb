require "test_helper"

class Steps::ResolveTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "r-test@example.com", password: "password123!", password_confirmation: "password123!")
    @workflow = Workflow.create!(title: "Test", user: @user)
  end

  test "resolve step is always terminal" do
    step = Steps::Resolve.create!(workflow: @workflow, position: 0, title: "R1")
    assert step.terminal?
  end

  test "resolve step validates resolution_type" do
    step = Steps::Resolve.new(workflow: @workflow, position: 0, title: "R1", resolution_type: "invalid")
    assert_not step.valid?
  end

  test "resolve step allows valid resolution_type" do
    step = Steps::Resolve.new(workflow: @workflow, position: 0, title: "R1", resolution_type: "success")
    assert step.valid?, step.errors.full_messages.join(", ")
  end
end
