require "test_helper"

class ScenariosControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create user directly instead of using fixtures (must be editor or admin to create workflows)
    @user = User.create!(
      email: "user-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Test Workflow", user: @user)
    Steps::Question.create!(workflow: @workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
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
    workflow = Workflow.create!(title: "Any Workflow", user: @user, is_public: false)
    Steps::Question.create!(workflow: workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
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
    own_workflow = Workflow.create!(title: "My Workflow", user: editor, is_public: false)
    Steps::Question.create!(workflow: own_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
    public_workflow = Workflow.create!(title: "Public Workflow", user: @user, is_public: true)
    Steps::Question.create!(workflow: public_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
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
    private_workflow = Workflow.create!(title: "Private Workflow", user: @user, is_public: false)
    Steps::Question.create!(workflow: private_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
    sign_in editor

    get new_workflow_scenario_path(private_workflow)

    assert_redirected_to workflows_path
    assert_equal "You don't have permission to view this workflow.", flash[:alert]
  end

  test "user should be redirected to play from scenario on public workflow" do
    regular_user = User.create!(
      email: "user-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    public_workflow = Workflow.create!(title: "Public Workflow", user: @user, is_public: true)
    Steps::Question.create!(workflow: public_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
    sign_in regular_user

    get new_workflow_scenario_path(public_workflow)

    assert_redirected_to play_path
  end

  test "user should not be able to run scenario on private workflow" do
    regular_user = User.create!(
      email: "user-sim2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    private_workflow = Workflow.create!(title: "Private Workflow", user: @user, is_public: false)
    Steps::Question.create!(workflow: private_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
    sign_in regular_user

    get new_workflow_scenario_path(private_workflow)

    assert_redirected_to play_path
  end

  # IDOR Tests — users cannot access other users' scenarios
  test "user cannot view another user's scenario" do
    other_user = User.create!(
      email: "other-sim-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(title: "Other Workflow", user: other_user, is_public: true)
    Steps::Question.create!(workflow: other_workflow, position: 0, uuid: SecureRandom.uuid, title: "Q1", question: "What?")
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
    other_workflow = Workflow.create!(title: "Other Workflow", user: other_user, is_public: true)
    Steps::Question.create!(workflow: other_workflow, position: 0, uuid: SecureRandom.uuid, title: "Q1", question: "What?")
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
    other_workflow = Workflow.create!(title: "Other Workflow", user: other_user, is_public: true)
    Steps::Question.create!(workflow: other_workflow, position: 0, uuid: SecureRandom.uuid, title: "Q1", question: "What?")
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
    other_workflow = Workflow.create!(title: "Other Workflow", user: other_user, is_public: true)
    Steps::Question.create!(workflow: other_workflow, position: 0, uuid: SecureRandom.uuid, title: "Q1", question: "What?")
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

  # Sub-flow seamless transition tests
  test "step action renders root parent workflow title for child scenario" do
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    q = Steps::Question.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CQ1", question: "Child question?")
    Steps::Resolve.create!(workflow: child_wf, position: 1, uuid: SecureRandom.uuid, title: "CDone")

    parent_scenario = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, purpose: "simulation",
      status: "awaiting_subflow", resume_node_uuid: SecureRandom.uuid,
      execution_path: [{ "step_title" => "Sub", "step_type" => "sub_flow", "subflow_started" => true }]
    )
    child_scenario = Scenario.create!(
      workflow: child_wf, user: @user, parent_scenario: parent_scenario,
      inputs: {}, purpose: "simulation", status: "active",
      current_node_uuid: q.uuid, execution_path: []
    )

    get step_scenario_path(child_scenario)

    assert_response :success
    assert_match @workflow.title, response.body
    assert_no_match(/Child WF/, response.body)
  end

  test "step action does not show sub-flow banner for child scenario" do
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    q = Steps::Question.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CQ1", question: "Child question?")
    Steps::Resolve.create!(workflow: child_wf, position: 1, uuid: SecureRandom.uuid, title: "CDone")

    parent_scenario = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, purpose: "simulation",
      status: "awaiting_subflow", resume_node_uuid: SecureRandom.uuid,
      execution_path: [{ "step_title" => "Sub", "step_type" => "sub_flow", "subflow_started" => true }]
    )
    child_scenario = Scenario.create!(
      workflow: child_wf, user: @user, parent_scenario: parent_scenario,
      inputs: {}, purpose: "simulation", status: "active",
      current_node_uuid: q.uuid, execution_path: []
    )

    get step_scenario_path(child_scenario)

    assert_response :success
    assert_no_match(/Sub-workflow of/, response.body)
    assert_no_match(/completing will return you to the main workflow/, response.body)
  end

  test "next_step auto-returns to parent when child completes" do
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    resolve_step = Steps::Resolve.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CDone")

    # Create a real SubFlow step in the parent workflow so process_subflow_completion
    # can find resume_node_uuid and advance to the next parent step
    sf_step = Steps::SubFlow.create!(workflow: @workflow, position: 1, uuid: SecureRandom.uuid, title: "SubStep")
    parent_resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: sf_step, target_step: parent_resolve, position: 0)

    parent_scenario = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, purpose: "simulation",
      status: "awaiting_subflow", resume_node_uuid: sf_step.uuid,
      execution_path: [{ "step_title" => "Sub", "step_type" => "sub_flow", "subflow_started" => true }],
      current_node_uuid: sf_step.uuid
    )
    child_scenario = Scenario.create!(
      workflow: child_wf, user: @user, parent_scenario: parent_scenario,
      inputs: {}, purpose: "simulation", status: "active",
      current_node_uuid: resolve_step.uuid, execution_path: []
    )

    post next_step_scenario_path(child_scenario), params: { answer: "" }

    assert_redirected_to step_scenario_path(parent_scenario)
  end

  test "empty sub-flow auto-progresses silently back to parent" do
    child_wf = Workflow.create!(title: "Empty Child WF", user: @user)
    resolve_step = Steps::Resolve.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CDone")

    # Create a real SubFlow step in the parent workflow so process_subflow_completion
    # can find resume_node_uuid and advance to the next parent step
    sf_step = Steps::SubFlow.create!(workflow: @workflow, position: 1, uuid: SecureRandom.uuid, title: "SubStep")
    parent_resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: sf_step, target_step: parent_resolve, position: 0)

    parent_scenario = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, purpose: "simulation",
      status: "awaiting_subflow", resume_node_uuid: sf_step.uuid,
      execution_path: [{ "step_title" => "Sub", "step_type" => "sub_flow", "subflow_started" => true }],
      current_node_uuid: sf_step.uuid
    )
    child_scenario = Scenario.create!(
      workflow: child_wf, user: @user, parent_scenario: parent_scenario,
      inputs: {}, purpose: "simulation", status: "active",
      current_node_uuid: resolve_step.uuid, execution_path: []
    )

    get step_scenario_path(child_scenario)
    assert_response :redirect
  end

  test "step view disables back button on first child step" do
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    q = Steps::Question.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CQ1", question: "Child question?")
    Steps::Resolve.create!(workflow: child_wf, position: 1, uuid: SecureRandom.uuid, title: "CDone")

    parent_scenario = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, purpose: "simulation",
      status: "awaiting_subflow", resume_node_uuid: SecureRandom.uuid,
      execution_path: [{ "step_title" => "P1", "step_type" => "question" }]
    )
    child_scenario = Scenario.create!(
      workflow: child_wf, user: @user, parent_scenario: parent_scenario,
      inputs: {}, purpose: "simulation", status: "active",
      current_node_uuid: q.uuid, execution_path: []
    )

    get step_scenario_path(child_scenario)

    assert_response :success
    assert_no_match(/back=true/, response.body)
  end
end
