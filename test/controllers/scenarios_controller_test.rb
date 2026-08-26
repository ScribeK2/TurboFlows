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

  # An "empty" sub-flow is one whose child workflow opens straight onto a
  # Resolve. The user should never see it — but that traversal is POST work now,
  # so this drives it through next_step rather than constructing the halfway
  # state and expecting GET to finish the job.
  test "empty sub-flow is traversed in a single answer" do
    child_wf = Workflow.create!(title: "Empty Child WF", user: @user)
    Steps::Resolve.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CDone")

    workflow = Workflow.create!(title: "Empty SF Parent", user: @user)
    q = Steps::Question.create!(workflow: workflow, position: 0, uuid: SecureRandom.uuid,
                                title: "Q", question: "Q?", variable_name: "qv")
    sf_step = Steps::SubFlow.create!(workflow: workflow, position: 1, uuid: SecureRandom.uuid,
                                     title: "SubStep", sub_flow_workflow_id: child_wf.id)
    parent_resolve = Steps::Resolve.create!(workflow: workflow, position: 2, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: q, target_step: sf_step, position: 0)
    Transition.create!(step: sf_step, target_step: parent_resolve, position: 0)
    workflow.update!(start_step: q)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, inputs: {}, results: {}, purpose: "simulation",
      status: "active", current_node_uuid: q.uuid, execution_path: []
    )

    post next_step_scenario_path(scenario), params: { answer: "yes" }

    scenario.reload
    assert_equal parent_resolve.uuid, scenario.current_node_uuid,
                 "the sub-flow had nothing to ask, so one answer should carry the run past it"
    assert_redirected_to step_scenario_path(scenario)
  end

  # The halfway state the previous version of the test built by hand. It should
  # not arise any more, but if it does the runner says so rather than healing it
  # inside a GET.
  test "a run stranded mid-sub-flow offers to resume rather than moving itself" do
    child_wf = Workflow.create!(title: "Stranded Child WF", user: @user)
    resolve_step = Steps::Resolve.create!(workflow: child_wf, position: 0, uuid: SecureRandom.uuid, title: "CDone")

    workflow = Workflow.create!(title: "Stranded Parent", user: @user)
    sf_step = Steps::SubFlow.create!(workflow: workflow, position: 0, uuid: SecureRandom.uuid,
                                     title: "SubStep", sub_flow_workflow_id: child_wf.id)
    parent_resolve = Steps::Resolve.create!(workflow: workflow, position: 1, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: sf_step, target_step: parent_resolve, position: 0)
    workflow.update!(start_step: sf_step)

    parent_scenario = Scenario.create!(
      workflow: workflow, user: @user, inputs: {}, results: {}, purpose: "simulation",
      status: "awaiting_subflow", resume_node_uuid: sf_step.uuid,
      execution_path: [{ "step_title" => "Sub", "step_type" => "sub_flow", "subflow_started" => true }],
      current_node_uuid: sf_step.uuid
    )
    child_scenario = Scenario.create!(
      workflow: child_wf, user: @user, parent_scenario: parent_scenario,
      inputs: {}, results: {}, purpose: "simulation", status: "active",
      current_node_uuid: resolve_step.uuid, execution_path: []
    )

    get step_scenario_path(child_scenario)

    assert_response :success
    assert_predicate child_scenario.reload, :parked?
    assert_equal "active", child_scenario.status, "a read must not move the run"
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

  # Turbo 8 prefetches links on hover by default and this app opts out nowhere,
  # so a GET that rewinds the run fires when the pointer merely passes over the
  # control — and go_back is not idempotent, so twice over is two steps back.
  test "GET step does not rewind the run" do
    workflow = Workflow.create!(title: "Prefetch WF", user: @user)
    action = Steps::Action.create!(
      workflow: workflow, position: 0, uuid: SecureRandom.uuid, title: "Act",
      output_fields: [{ "name" => "ticket_id", "value" => "T-42" }]
    )
    resolve = Steps::Resolve.create!(workflow: workflow, position: 1, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: action, target_step: resolve, position: 0)
    workflow.update!(start_step: action)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: action.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)
    node_before = scenario.reload.current_node_uuid
    path_before = scenario.execution_path.length

    get step_scenario_path(scenario, back: true)

    scenario.reload
    assert_equal node_before, scenario.current_node_uuid, "a GET must not move the run"
    assert_equal path_before, scenario.execution_path.length
    assert_equal "T-42", scenario.results["ticket_id"]
  end

  test "back is a POST and rewinds one step" do
    workflow = Workflow.create!(title: "Back WF", user: @user)
    q1 = Steps::Question.create!(workflow: workflow, position: 0, uuid: SecureRandom.uuid,
                                 title: "Q1", question: "Q1?", variable_name: "q1_var")
    q2 = Steps::Question.create!(workflow: workflow, position: 1, uuid: SecureRandom.uuid,
                                 title: "Q2", question: "Q2?", variable_name: "q2_var")
    resolve = Steps::Resolve.create!(workflow: workflow, position: 2, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: q1, target_step: q2, position: 0)
    Transition.create!(step: q2, target_step: resolve, position: 0)
    workflow.update!(start_step: q1)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step("Yes")

    post back_scenario_path(scenario)

    assert_redirected_to step_scenario_path(scenario)
    scenario.reload
    assert_equal q1.uuid, scenario.current_node_uuid
    assert_not scenario.results.key?("q1_var")
  end
end
