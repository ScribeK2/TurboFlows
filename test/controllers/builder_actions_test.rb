require "test_helper"

class BuilderActionsRoutingTest < ActionDispatch::IntegrationTest
  fixtures :users, :workflows

  setup do
    @user = users(:admin_user)
    sign_in @user
    @workflow = workflows(:graph_mode_workflow)
  end

  test "panel_edit route responds" do
    step = @workflow.steps.create!(type: "Steps::Action", title: "Test Step", position: 0)
    get panel_edit_workflow_step_path(@workflow, step)
    assert_response :success
  end

  test "flow_diagram route responds" do
    get workflow_flow_diagram_path(@workflow)
    assert_response :success
  end

  test "settings route responds" do
    get workflow_settings_path(@workflow)
    assert_response :success
  end
end
