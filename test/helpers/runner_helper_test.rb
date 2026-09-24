require "test_helper"

class RunnerHelperTest < ActionView::TestCase
  include ScenariosHelper
  include RunnerHelper

  setup do
    @user = User.create!(
      email: "runner-helper-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Runner Helper WF", user: @user)
  end

  test "runner_auto_advances? is true for yes_no and option cards" do
    yes_no = Steps::Question.new(answer_type: "yes_no")
    multiple = Steps::Question.new(answer_type: "multiple_choice",
                                   options: [{ "label" => "A", "value" => "a" }])
    dropdown = Steps::Question.new(answer_type: "dropdown",
                                   options: [{ "label" => "A", "value" => "a" }])
    empty_mc = Steps::Question.new(answer_type: "multiple_choice", options: [])

    assert runner_auto_advances?(yes_no)
    assert runner_auto_advances?(multiple)
    assert_not runner_auto_advances?(dropdown)
    assert_not runner_auto_advances?(empty_mc)
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

  test "runner_back_button posts to the shell's back route rather than linking to a GET" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation", inputs: {}, results: {},
      execution_path: [{ "step_title" => "S1", "step_type" => "question", "results_delta" => {} }]
    )

    [back_scenario_path(scenario), player_scenario_back_path(scenario)].each do |url|
      result = runner_back_button(scenario, url)

      assert_includes result, "Back"
      assert_includes result, url
      assert_includes result, "post", "a GET that rewinds the run is fired by Turbo's hover prefetch"
    end
  end

  test "runner_back_button is hidden when there is nothing to go back to" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "live", execution_path: [], inputs: {})

    assert_nil runner_back_button(scenario, player_scenario_back_path(scenario))
  end

  test "runner_back_button is hidden for a run whose entries predate the undo log" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live", inputs: {},
      execution_path: [{ "step_title" => "S1", "step_type" => "question" }]
    )

    assert_nil runner_back_button(scenario, player_scenario_back_path(scenario)),
               "offering Back on a run it cannot rewind is how the old rebuild lost data"
  end
end
