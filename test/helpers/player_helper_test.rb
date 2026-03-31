require "test_helper"

class PlayerHelperTest < ActionView::TestCase
  include PlayerHelper

  setup do
    @user = User.create!(
      email: "player-helper-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(title: "Helper Test WF", user: @user)
  end

  test "player_back_button returns link when execution_path has entries" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live",
      execution_path: [{ "step_title" => "S1", "step_type" => "question" }],
      inputs: {}
    )
    result = player_back_button(scenario)
    assert_not_nil result
    assert_includes result, "Back"
    assert_includes result, player_scenario_back_path(scenario)
  end

  test "player_back_button returns nil when execution_path is empty" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live",
      execution_path: [],
      inputs: {}
    )
    assert_nil player_back_button(scenario)
  end
end
