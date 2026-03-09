require "test_helper"

class Steps::EscalateTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "e-test@example.com", password: "password123!", password_confirmation: "password123!")
    @workflow = Workflow.create!(title: "Test", user: @user)
  end

  test "escalate step has rich text notes" do
    step = Steps::Escalate.create!(workflow: @workflow, position: 0, title: "E1")
    step.notes = "<p>Escalation notes</p>"
    step.save!
    assert_includes step.notes.body.to_s, "Escalation notes"
  end

  test "escalate step validates target_type" do
    step = Steps::Escalate.new(workflow: @workflow, position: 0, title: "E1", target_type: "invalid")
    assert_not step.valid?
  end

  test "escalate step validates priority" do
    step = Steps::Escalate.new(workflow: @workflow, position: 0, title: "E1", priority: "invalid")
    assert_not step.valid?
  end

  test "escalate step allows valid target_type and priority" do
    step = Steps::Escalate.new(workflow: @workflow, position: 0, title: "E1", target_type: "team", priority: "high")
    assert step.valid?, step.errors.full_messages.join(", ")
  end
end
