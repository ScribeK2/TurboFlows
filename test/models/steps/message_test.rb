require "test_helper"

class Steps::MessageTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "m-test@example.com", password: "password123!", password_confirmation: "password123!")
    @workflow = Workflow.create!(title: "Test", user: @user)
  end

  test "message step has rich text content" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "M1")
    step.content = "<p>Hello</p>"
    step.save!
    assert_includes step.content.body.to_s, "Hello"
  end

  test "message step has can_resolve flag" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "M1", can_resolve: true)
    assert step.can_resolve
  end
end
