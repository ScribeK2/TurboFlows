require "test_helper"

class RenderStepTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "render_step_test@example.com",
      password: "password123!",
      role: "admin"
    )
    @workflow = Workflow.create!(
      title: "Test Workflow for Render Step",
      user: @user,
      status: "draft"
    )
    sign_in @user
  end

  teardown do
    @workflow&.reload&.destroy
    @user&.destroy
  end

  test "render_step returns valid step HTML for question type" do
    post render_step_workflow_path(@workflow), params: {
      step_type: 'question',
      step_index: 0,
      step_data: { title: 'Test Question', question: 'Is this working?' }
    }, as: :json

    assert_response :success
    assert_includes response.body, 'step-card'
    assert_includes response.body, 'data-step-index'
    assert_includes response.body, 'collapsible-step'
  end

  test "render_step returns valid step HTML for action type" do
    post render_step_workflow_path(@workflow), params: {
      step_type: 'action',
      step_index: 1,
      step_data: { title: 'Test Action', instructions: 'Do something' }
    }, as: :json

    assert_response :success
    assert_includes response.body, 'step-card'
    assert_includes response.body, 'data-controller="collapsible-step"'
  end

  test "render_step returns valid step HTML for message type" do
    post render_step_workflow_path(@workflow), params: {
      step_type: 'message',
      step_index: 2,
      step_data: { title: 'Test Message', content: 'Hello' }
    }, as: :json

    assert_response :success
    assert_includes response.body, 'step-card'
    assert_includes response.body, 'message'
  end
end
