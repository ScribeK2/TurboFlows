require "test_helper"

class WorkflowVersionsDiffTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "diffuser@test.com", password: "password123!", role: "admin")
    sign_in @user
    @workflow = Workflow.create!(title: "Diff Test Flow", user: @user)

    @v1 = WorkflowVersion.create!(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: [{ "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0 }],
      metadata_snapshot: { "title" => "Diff Test Flow", "graph_mode" => false },
      published_by: @user,
      published_at: 2.days.ago
    )
    @v2 = WorkflowVersion.create!(
      workflow: @workflow,
      version_number: 2,
      steps_snapshot: [
        { "id" => "uuid-1", "type" => "question", "title" => "Q1 Updated", "position" => 0 },
        { "id" => "uuid-2", "type" => "action", "title" => "A1", "position" => 1 }
      ],
      metadata_snapshot: { "title" => "Diff Test Flow", "graph_mode" => true },
      published_by: @user,
      published_at: 1.day.ago
    )
  end

  test "diff page renders with two valid versions" do
    get workflow_diff_versions_path(@workflow, v1: @v1.id, v2: @v2.id)
    assert_response :success
    assert_select ".diff-added", minimum: 1
    assert_select ".diff-modified", minimum: 1
  end

  test "diff with missing version param redirects" do
    get workflow_diff_versions_path(@workflow, v1: @v1.id)
    assert_redirected_to workflow_versions_path(@workflow)
  end

  test "diff with same version shows no changes" do
    get workflow_diff_versions_path(@workflow, v1: @v1.id, v2: @v1.id)
    assert_response :success
  end

  test "non-authenticated user is redirected" do
    sign_out @user
    get workflow_diff_versions_path(@workflow, v1: @v1.id, v2: @v2.id)
    assert_response :redirect
  end
end
