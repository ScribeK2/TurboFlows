require "test_helper"

class PlayerControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email: "playeradmin-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @regular = User.create!(
      email: "playeruser-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(title: "Player Flow", user: @admin, status: "published", is_public: true)
    step = Steps::Resolve.create!(
      workflow: @workflow,
      title: "Done",
      uuid: SecureRandom.uuid,
      position: 0,
      resolution_type: "success"
    )
    @workflow.update!(start_step: step)
    WorkflowPublisher.publish(@workflow, @admin)
  end

  # === Index ===

  test "authenticated user can access player index" do
    sign_in @regular
    get play_path
    assert_response :success
  end

  test "unauthenticated user is redirected from player index" do
    get play_path
    assert_response :redirect
  end

  test "player uses player layout" do
    sign_in @regular
    get play_path
    assert_select "body.player-layout"
  end

  # === Start ===

  test "authenticated user can start a workflow" do
    sign_in @regular
    assert_difference("Scenario.count") do
      post play_workflow_path(@workflow)
    end
    assert_response :redirect
    assert Scenario.exists?(workflow: @workflow, user: @regular)
  end

  test "unauthenticated user cannot start a workflow" do
    post play_workflow_path(@workflow)
    assert_response :redirect
    assert_redirected_to new_user_session_path
  end

  # === Step & Navigation ===

  test "authenticated user can view current step" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    get player_scenario_step_path(scenario)
    # Scenario is active with a resolve step ready — renders step view
    assert_response :success
  end

  test "other user cannot access someone else's scenario" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last

    other_user = User.create!(
      email: "other-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    sign_in other_user
    get player_scenario_step_path(scenario)
    assert_response :forbidden
  end

  # === Show (completed scenario) ===

  test "authenticated user can view completed scenario" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    # Process through the resolve step so scenario completes
    scenario.process_step
    scenario.save!
    get player_scenario_show_path(scenario)
    assert_response :success
  end
end
