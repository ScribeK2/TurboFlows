require "test_helper"

class WorkflowPublishingIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "integration-pub@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(
      title: "Integration Workflow",
      user: @editor
    )
    @q1_step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "What?")
    @resolve_step = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: @q1_step, target_step: @resolve_step, position: 0)
    @workflow.update_column(:start_step_id, @q1_step.id)
    sign_in @editor
  end

  test "full publishing lifecycle: publish, edit, republish, view history, restore" do
    # 1. Publish v1
    post workflow_publishing_path(@workflow), params: { changelog: "Initial release" }
    assert_redirected_to workflow_path(@workflow)
    @workflow.reload
    assert_equal 1, @workflow.published_version.version_number
    v1_id = @workflow.published_version.id

    # 2. Edit workflow (simulates builder changes)
    @workflow.update_column(:start_step_id, nil)
    @workflow.steps.destroy_all
    new_action = Steps::Action.create!(workflow: @workflow, position: 0, title: "New Action")
    new_resolve = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "End", resolution_type: "success")
    Transition.create!(step: new_action, target_step: new_resolve, position: 0)
    @workflow.update_column(:start_step_id, new_action.id)

    # 3. Published version is still v1 with old steps
    @workflow.reload
    assert_equal v1_id, @workflow.published_version_id
    assert_equal "Q1", @workflow.published_version.steps_snapshot.first["title"]

    # 4. Publish v2
    post workflow_publishing_path(@workflow), params: { changelog: "Changed to action step" }
    @workflow.reload
    assert_equal 2, @workflow.published_version.version_number
    assert_equal "New Action", @workflow.published_version.steps_snapshot.first["title"]

    # 5. View version history
    get workflow_versions_path(@workflow)
    assert_response :success
    assert_match "Initial release", response.body
    assert_match "Changed to action step", response.body

    # 6. Restore v1
    v1 = @workflow.versions.find_by(version_number: 1)
    post workflow_restore_version_path(@workflow, v1)
    assert_redirected_to edit_workflow_path(@workflow)
    @workflow.reload
    assert_equal "Q1", @workflow.steps.order(:position).first.title

    # 7. published_version is still v2 (restore only changes draft, not published)
    assert_equal 2, @workflow.published_version.version_number
  end
end
