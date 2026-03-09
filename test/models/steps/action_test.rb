require "test_helper"

class Steps::ActionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "a-test@example.com", password: "password123!", password_confirmation: "password123!")
    @workflow = Workflow.create!(title: "Test", user: @user)
  end

  test "action step has rich text instructions" do
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "A1")
    step.instructions = "<p>Do this thing</p>"
    step.save!
    assert_includes step.instructions.body.to_s, "Do this thing"
  end

  test "action step has can_resolve flag" do
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "A1", can_resolve: true)
    assert step.can_resolve
  end
end
