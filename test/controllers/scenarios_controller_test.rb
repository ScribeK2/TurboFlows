require "test_helper"

class ScenariosControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  # Don't use fixtures - create data directly
  self.use_transactional_tests = true

  def setup
    # Create user directly instead of using fixtures (must be editor or admin to create workflows)
    @user = User.create!(
      email: "user-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(
      title: "Test Workflow",
      description: "A test workflow",
      user: @user,
      steps: [
        { type: "question", title: "Question 1", question: "What is your name?" }
      ]
    )
    sign_in @user
  end

  test "should get new scenario" do
    get new_workflow_scenario_path(@workflow)

    assert_response :success
  end

  test "should create scenario" do
    assert_difference("Scenario.count") do
      post workflow_scenarios_path(@workflow), params: {
        scenario: {
          inputs: { "0" => "John Doe" }
        }
      }
    end

    scenario = Scenario.last
    # Redirects to step path for interactive scenario
    assert_response :redirect
    assert_equal @workflow, scenario.workflow
    assert_equal @user, scenario.user
  end

  test "should require authentication" do
    sign_out @user
    get new_workflow_scenario_path(@workflow)

    assert_redirected_to new_user_session_path
  end

  # Authorization Tests
  test "admin should be able to run scenario on any workflow" do
    admin = User.create!(
      email: "admin-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    workflow = Workflow.create!(
      title: "Any Workflow",
      user: @user,
      is_public: false,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
    sign_in admin

    get new_workflow_scenario_path(workflow)

    assert_response :success
  end

  test "editor should be able to run scenario on workflows they can view" do
    editor = User.create!(
      email: "editor-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    own_workflow = Workflow.create!(
      title: "My Workflow",
      user: editor,
      is_public: false,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
    public_workflow = Workflow.create!(
      title: "Public Workflow",
      user: @user,
      is_public: true,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
    sign_in editor

    get new_workflow_scenario_path(own_workflow)

    assert_response :success

    get new_workflow_scenario_path(public_workflow)

    assert_response :success
  end

  test "editor should not be able to run scenario on other user's private workflow" do
    editor = User.create!(
      email: "editor-sim2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    private_workflow = Workflow.create!(
      title: "Private Workflow",
      user: @user,
      is_public: false,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
    sign_in editor

    get new_workflow_scenario_path(private_workflow)

    assert_redirected_to workflows_path
    assert_equal "You don't have permission to view this workflow.", flash[:alert]
  end

  test "user should be able to run scenario on public workflow" do
    regular_user = User.create!(
      email: "user-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    public_workflow = Workflow.create!(
      title: "Public Workflow",
      user: @user,
      is_public: true,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
    sign_in regular_user

    get new_workflow_scenario_path(public_workflow)

    assert_response :success
  end

  test "user should not be able to run scenario on private workflow" do
    regular_user = User.create!(
      email: "user-sim2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    private_workflow = Workflow.create!(
      title: "Private Workflow",
      user: @user,
      is_public: false,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
    sign_in regular_user

    get new_workflow_scenario_path(private_workflow)

    assert_redirected_to workflows_path
    assert_equal "You don't have permission to view this workflow.", flash[:alert]
  end

  # IDOR Tests — users cannot access other users' scenarios
  test "user cannot view another user's scenario" do
    other_user = User.create!(
      email: "other-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: other_user,
      is_public: true,
      steps: [{ type: "question", title: "Q1", question: "What?" }]
    )
    other_scenario = Scenario.create!(
      workflow: other_workflow,
      user: other_user,
      current_step_index: 0,
      execution_path: [],
      results: {},
      inputs: {}
    )

    get scenario_path(other_scenario)
    assert_response :not_found
  end

  test "user cannot access step of another user's scenario" do
    other_user = User.create!(
      email: "other-step-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: other_user,
      is_public: true,
      steps: [{ type: "question", title: "Q1", question: "What?" }]
    )
    other_scenario = Scenario.create!(
      workflow: other_workflow,
      user: other_user,
      current_step_index: 0,
      execution_path: [],
      results: {},
      inputs: {}
    )

    get step_scenario_path(other_scenario)
    assert_response :not_found
  end

  test "user cannot advance another user's scenario" do
    other_user = User.create!(
      email: "other-next-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: other_user,
      is_public: true,
      steps: [{ type: "question", title: "Q1", question: "What?" }]
    )
    other_scenario = Scenario.create!(
      workflow: other_workflow,
      user: other_user,
      current_step_index: 0,
      execution_path: [],
      results: {},
      inputs: {}
    )

    post next_step_scenario_path(other_scenario), params: { answer: "test" }
    assert_response :not_found
  end

  test "user cannot stop another user's scenario" do
    other_user = User.create!(
      email: "other-stop-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: other_user,
      is_public: true,
      steps: [{ type: "question", title: "Q1", question: "What?" }]
    )
    other_scenario = Scenario.create!(
      workflow: other_workflow,
      user: other_user,
      current_step_index: 0,
      execution_path: [],
      results: {},
      inputs: {}
    )

    post stop_scenario_path(other_scenario)
    assert_response :not_found
  end
end
