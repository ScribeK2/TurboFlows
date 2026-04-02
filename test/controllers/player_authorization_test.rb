require "test_helper"

class PlayerAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner@example.com", password: "password123456")
    @other_user = User.create!(email: "other@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Shared WF", user: @owner, status: "published")
    @workflow.update!(share_token: SecureRandom.hex(16))
  end

  test "owner can access their own scenario" do
    sign_in @owner
    scenario = Scenario.create!(
      workflow: @workflow, user: @owner, purpose: "live",
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [], results: {}, inputs: {}
    )
    get player_scenario_step_path(scenario)
    assert_response :success
  end

  test "anonymous user can access scenario on shared workflow created via share flow" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @workflow.user, purpose: "live",
      shared_access: true,
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [], results: {}, inputs: {}
    )
    get player_scenario_step_path(scenario)
    assert_response :success
  end

  test "anonymous user cannot access non-shared scenario" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @owner, purpose: "live",
      shared_access: false,
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [], results: {}, inputs: {}
    )
    get player_scenario_step_path(scenario)
    assert_response :forbidden
  end

  test "authenticated user cannot access another users scenario on shared workflow" do
    sign_in @other_user
    scenario = Scenario.create!(
      workflow: @workflow, user: @owner, purpose: "live",
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [], results: {}, inputs: {}
    )
    get player_scenario_step_path(scenario)
    assert_response :forbidden
  end
end
