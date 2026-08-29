require "test_helper"

class RunnerHelperTest < ActionView::TestCase
  include ScenariosHelper

  setup do
    @user = User.create!(
      email: "runner-helper-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Runner Helper WF", user: @user)
  end

  test "option value and label accept hashes or plain strings" do
    assert_equal "yes", runner_option_value({ "value" => "yes", "label" => "Yes" })
    assert_equal "Yes", runner_option_label({ "value" => "yes", "label" => "Yes" })

    # Authored as a bare string — the Scenario runner used to render nothing here.
    assert_equal "Escalate", runner_option_value("Escalate")
    assert_equal "Escalate", runner_option_label("Escalate")
  end

  test "option value falls back to label when only one is present" do
    assert_equal "Yes", runner_option_value({ "label" => "Yes" })
    assert_equal "yes", runner_option_label({ "value" => "yes" })
  end

  test "input type and placeholder follow the answer type" do
    assert_equal "number", runner_input_type("number")
    assert_equal "date", runner_input_type("date")
    assert_equal "text", runner_input_type("free_text")
    assert_equal "text", runner_input_type(nil)

    assert_equal "Enter a number", runner_input_placeholder("number")
    assert_equal "YYYY-MM-DD", runner_input_placeholder("date")
    assert_equal "Type your answer...", runner_input_placeholder(nil)
  end
end
