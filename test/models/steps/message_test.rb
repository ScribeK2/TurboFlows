require "test_helper"

module Steps
  class MessageTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "test-message@example.com", password: "password123456")
      @workflow = Workflow.create!(title: "Message Test", user: @user)
    end

    test "valid with title only" do
      step = Steps::Message.new(workflow: @workflow, title: "Welcome", position: 0)
      assert_predicate step, :valid?
    end

    test "has rich text content" do
      step = Steps::Message.create!(workflow: @workflow, title: "M1", position: 0)
      step.content = "<p>Hello <strong>customer</strong></p>"
      step.save!
      assert_equal "Hello customer", step.content.to_plain_text
    end

    test "outcome_summary returns truncated content" do
      step = Steps::Message.create!(workflow: @workflow, title: "M1", position: 0)
      step.content = "This is a message to the agent"
      step.save!
      summary = step.outcome_summary
      assert_includes summary, "This is a message"
    end

    test "step_type returns message" do
      step = Steps::Message.create!(workflow: @workflow, title: "M1", position: 0)
      assert_equal "message", step.step_type
    end
  end
end
