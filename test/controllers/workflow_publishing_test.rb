require "test_helper"

class WorkflowPublishingTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "editor-pub@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @regular_user = User.create!(
      email: "user-pub@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    @workflow = Workflow.create!(
      title: "Publishable Workflow",
      user: @editor
    )
    @q1_step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "What?")
    @resolve_step = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: @q1_step, target_step: @resolve_step, position: 0)
    @workflow.update_column(:start_step_id, @q1_step.id)
  end

  test "editor can publish their own workflow" do
    sign_in @editor

    assert_difference "WorkflowVersion.count", 1 do
      post workflow_publishing_path(@workflow), params: { changelog: "First publish" }
    end

    assert_redirected_to workflow_path(@workflow)
    follow_redirect!
    assert_match(/published/i, response.body)
  end

  test "regular user cannot publish" do
    sign_in @regular_user

    assert_no_difference "WorkflowVersion.count" do
      post workflow_publishing_path(@workflow)
    end

    assert_response :redirect
  end

  test "publish fails for workflow with no steps" do
    sign_in @editor
    @workflow.update_column(:start_step_id, nil)
    @workflow.steps.destroy_all

    assert_no_difference "WorkflowVersion.count" do
      post workflow_publishing_path(@workflow)
    end

    assert_redirected_to workflow_path(@workflow)
    follow_redirect!
    assert_match(/no steps/i, response.body)
  end

  test "editor can view version history" do
    sign_in @editor
    WorkflowPublisher.publish(@workflow, @editor, changelog: "v1")
    WorkflowPublisher.publish(@workflow, @editor, changelog: "v2")

    get versions_workflow_path(@workflow)

    assert_response :success
    assert_match "v1", response.body
    assert_match "v2", response.body
  end

  test "editor can view a specific version" do
    sign_in @editor
    result = WorkflowPublisher.publish(@workflow, @editor)

    get workflow_version_path(@workflow, result.version)

    assert_response :success
    assert_match "Q1", response.body
  end

  test "editor can restore a version" do
    sign_in @editor
    WorkflowPublisher.publish(@workflow, @editor)
    # Change the workflow steps
    @workflow.update_column(:start_step_id, nil)
    @workflow.steps.destroy_all
    Steps::Action.create!(workflow: @workflow, position: 0, title: "Changed")
    version = @workflow.versions.last # version 1 (oldest)

    post restore_workflow_version_path(@workflow, version)

    assert_redirected_to edit_workflow_path(@workflow)
    @workflow.reload
    assert_equal "Q1", @workflow.steps.order(:position).first.title
  end
end
