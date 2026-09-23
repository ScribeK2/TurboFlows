require "test_helper"

class BuilderFlowTest < ActionDispatch::IntegrationTest
  fixtures :users, :workflows

  setup do
    @user = users(:admin_user)
    sign_in @user
  end

  test "viewing existing workflow shows builder in view mode" do
    workflow = workflows(:graph_mode_workflow)
    get workflow_path(workflow)

    assert_response :success
    assert_match 'data-builder-mode-value="view"', response.body
    assert_match workflow.title, response.body
    assert_select "button", text: "Run Scenario"
    assert_select "form[action=?]", workflow_publishing_path(workflow), count: 0
  end

  test "viewing workflow with edit param sets edit mode" do
    workflow = workflows(:graph_mode_workflow)
    get workflow_path(workflow, edit: true)

    assert_response :success
    assert_match 'data-builder-mode-value="edit"', response.body
    assert_match "Run Scenario", response.body
    assert_match "Publish", response.body
  end

  test "step row meta says Start and the continuation chip names its door" do
    workflow = Workflow.create!(title: "Overflow crumbs", user: @user)
    question = Steps::Question.create!(
      workflow: workflow, position: 0,
      title: "What do they want cancelled?", question: "What?"
    )
    resolve = Steps::Resolve.create!(
      workflow: workflow, position: 1,
      title: "Verify Client Account", resolution_type: "success"
    )
    Transition.create!(step: question, target_step: resolve, position: 0)
    workflow.update!(start_step: question)

    get workflow_path(workflow, edit: true)

    assert_response :success
    assert_select ".builder__step-meta", text: "Start"
    assert_select ".builder__outline-door--continue .builder__outline-chip", text: "Next"
  end

  test "adding a step via turbo stream appends step row" do
    workflow = workflows(:graph_mode_workflow)
    post workflow_steps_path(workflow),
         params: { step_type: "question" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "builder__step", response.body
  end

  test "panel_edit loads step editor in turbo frame" do
    workflow = workflows(:graph_mode_workflow)
    step = workflow.steps.create!(type: "Steps::Action", title: "Test", position: 0)

    get panel_edit_workflow_step_path(workflow, step)

    assert_response :success
    assert_match "builder-panel", response.body
  end

  test "flow_diagram renders diagram panel" do
    workflow = workflows(:graph_mode_workflow)
    get workflow_flow_diagram_path(workflow)

    assert_response :success
    assert_match "Flow Diagram", response.body
  end

  test "settings renders details panel" do
    workflow = workflows(:graph_mode_workflow)
    get workflow_settings_path(workflow)

    assert_response :success
    assert_match "Details", response.body
  end
end
