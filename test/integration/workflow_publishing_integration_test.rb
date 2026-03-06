require "test_helper"

class WorkflowPublishingIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "integration-pub@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @step_uuid = SecureRandom.uuid
    @workflow = Workflow.create!(
      title: "Integration Workflow",
      user: @editor,
      steps: [
        { "id" => @step_uuid, "type" => "question", "title" => "Q1", "question" => "What?" }
      ]
    )
    sign_in @editor
  end

  test "full publishing lifecycle: publish, edit, republish, view history, restore" do
    # 1. Publish v1
    post publish_workflow_path(@workflow), params: { changelog: "Initial release" }
    assert_redirected_to workflow_path(@workflow)
    @workflow.reload
    assert_equal 1, @workflow.published_version.version_number
    v1_id = @workflow.published_version.id

    # 2. Edit workflow (simulates builder changes)
    new_uuid = SecureRandom.uuid
    @workflow.update!(steps: [
      { "id" => new_uuid, "type" => "action", "title" => "New Action" }
    ])

    # 3. Published version is still v1 with old steps
    @workflow.reload
    assert_equal v1_id, @workflow.published_version_id
    assert_equal "Q1", @workflow.published_version.steps_snapshot.first["title"]

    # 4. Publish v2
    post publish_workflow_path(@workflow), params: { changelog: "Changed to action step" }
    @workflow.reload
    assert_equal 2, @workflow.published_version.version_number
    assert_equal "New Action", @workflow.published_version.steps_snapshot.first["title"]

    # 5. View version history
    get versions_workflow_path(@workflow)
    assert_response :success
    assert_match "Initial release", response.body
    assert_match "Changed to action step", response.body

    # 6. Restore v1
    v1 = @workflow.versions.find_by(version_number: 1)
    post restore_workflow_version_path(@workflow, v1)
    assert_redirected_to edit_workflow_path(@workflow)
    @workflow.reload
    assert_equal "Q1", @workflow.steps.first["title"]

    # 7. published_version is still v2 (restore only changes draft, not published)
    assert_equal 2, @workflow.published_version.version_number
  end
end
