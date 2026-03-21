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
  end

  test "viewing workflow with edit param sets edit mode" do
    workflow = workflows(:graph_mode_workflow)
    get workflow_path(workflow, edit: true)

    assert_response :success
    assert_match 'data-builder-mode-value="edit"', response.body
  end

  test "adding a step via turbo stream appends step row" do
    workflow = workflows(:graph_mode_workflow)
    post workflow_steps_path(workflow),
         params: { step_type: "question" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "builder__list-row", response.body
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
    get flow_diagram_workflow_path(workflow)

    assert_response :success
    assert_match "Flow Diagram", response.body
  end

  test "settings renders details panel" do
    workflow = workflows(:graph_mode_workflow)
    get settings_workflow_path(workflow)

    assert_response :success
    assert_match "Details", response.body
  end
end
