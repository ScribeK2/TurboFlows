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

  # Which messages the summary block still has to show once the fields have
  # taken the ones that belong to them.
  #
  # The fallback is defensive: nothing in Steps::Form can name a field that is
  # not in its own options today. It exists because a builder that autosaves can
  # edit a step between the render and the submit, and a message vanishing with
  # its field is worse than a message in the wrong place.
  def form_step(*names)
    Struct.new(:fields).new(names.map { |n| { "name" => n } })
  end

  test "a message whose field is on the page is left to that field" do
    unattached = runner_unattached_errors(
      form_step("phone"), ["Phone is required"], { "phone" => ["Phone is required"] }
    )

    assert_empty unattached, "showing it twice is how a form ends up shouting"
  end

  test "a message whose field is gone still gets said" do
    unattached = runner_unattached_errors(
      form_step("account"), ["Phone is required"], { "phone" => ["Phone is required"] }
    )

    assert_equal ["Phone is required"], unattached
  end

  test "a step with no field errors keeps every message in the block" do
    assert_equal ["Resolution notes are required"],
                 runner_unattached_errors(nil, ["Resolution notes are required"], {})
  end
end
