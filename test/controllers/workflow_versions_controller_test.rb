require "test_helper"

class WorkflowVersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email: "admin-wvc@example.com",
      password: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-wvc@example.com",
      password: "password123!",
      role: "editor"
    )
    @other_editor = User.create!(
      email: "other-wvc@example.com",
      password: "password123!",
      role: "editor"
    )
    @regular_user = User.create!(
      email: "user-wvc@example.com",
      password: "password123!",
      role: "user"
    )

    @workflow = Workflow.create!(title: "Version Test Flow", user: @editor)

    # Build a minimal publishable graph: Question → Resolve
    @q_step = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Start Question", question: "What now?"
    )
    @resolve_step = Steps::Resolve.create!(
      workflow: @workflow, position: 1, title: "All Done", resolution_type: "success"
    )
    Transition.create!(step: @q_step, target_step: @resolve_step, position: 0)
    @workflow.update_column(:start_step_id, @q_step.id)

    # Publish one version so tests have something to work with
    result = WorkflowPublisher.publish(@workflow, @editor, changelog: "Initial release")
    @version = result.version
  end

  # ──────────────────────────────────────────────────────────────
  # show
  # ──────────────────────────────────────────────────────────────

  test "show: owner can view a specific version" do
    sign_in @editor
    get workflow_version_path(@workflow, @version)
    assert_response :success
    assert_match "Start Question", response.body
  end

  test "show: admin can view any version" do
    sign_in @admin
    get workflow_version_path(@workflow, @version)
    assert_response :success
  end

  test "show: unauthenticated user is redirected to login" do
    get workflow_version_path(@workflow, @version)
    assert_response :redirect
    assert_redirected_to new_user_session_path
  end

  test "show: version belonging to a different workflow returns 404" do
    other_workflow = Workflow.create!(title: "Other Flow", user: @editor)
    other_q = Steps::Question.create!(workflow: other_workflow, position: 0, title: "Q", question: "Q?")
    other_r = Steps::Resolve.create!(workflow: other_workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: other_q, target_step: other_r, position: 0)
    other_workflow.update_column(:start_step_id, other_q.id)
    other_result = WorkflowPublisher.publish(other_workflow, @editor)
    other_version = other_result.version

    sign_in @editor
    get workflow_version_path(@workflow, other_version)
    assert_response :not_found
  end

  test "show: regular user who cannot view the workflow is redirected to play" do
    # Regular users are redirected to /play via ensure_can_view_workflow!
    # which redirects to workflows_path, but the workflow_versions_controller
    # uses ensure_can_view_workflow! directly.
    sign_in @regular_user
    get workflow_version_path(@workflow, @version)
    assert_redirected_to workflows_path
  end

  test "show: regular user can view a public workflow version" do
    @workflow.update!(is_public: true)
    sign_in @regular_user
    get workflow_version_path(@workflow, @version)
    assert_response :success
  end

  # ──────────────────────────────────────────────────────────────
  # restore
  # ──────────────────────────────────────────────────────────────

  test "restore: owner can restore a version" do
    sign_in @editor
    # Mutate the workflow after publishing
    @workflow.update_column(:start_step_id, nil)
    @workflow.steps.destroy_all
    Steps::Action.create!(workflow: @workflow, position: 0, title: "New Step")

    post workflow_restore_version_path(@workflow, @version)

    # edit_workflow redirects → workflow_path with edit:true
    assert_redirected_to edit_workflow_path(@workflow)
    assert_equal "Restored version #{@version.version_number}.", flash[:notice]

    @workflow.reload
    assert_equal "Start Question", @workflow.steps.order(:position).first.title
  end

  test "restore: admin can restore any workflow version" do
    sign_in @admin
    post workflow_restore_version_path(@workflow, @version)
    assert_redirected_to edit_workflow_path(@workflow)
  end

  test "restore: regular user is blocked by view-level authorization" do
    # Regular users cannot view the workflow (not public, not in an accessible group),
    # so ensure_can_view_workflow! fires before the edit-permission check.
    sign_in @regular_user
    post workflow_restore_version_path(@workflow, @version)
    assert_redirected_to workflows_path
  end

  test "restore: regular user blocked by edit-permission check on a public workflow" do
    # Make the workflow public so the regular user passes the view-level check,
    # then confirm the restore action's edit-permission guard kicks in.
    @workflow.update!(is_public: true)
    sign_in @regular_user
    post workflow_restore_version_path(@workflow, @version)
    # Regular users have no edit rights → redirected back to the workflow with alert
    assert_redirected_to workflow_path(@workflow)
  end

  test "restore: unauthenticated user is redirected to login" do
    post workflow_restore_version_path(@workflow, @version)
    assert_response :redirect
    assert_redirected_to new_user_session_path
  end

  test "restore: restores correct steps from snapshot" do
    sign_in @editor
    original_step_count = @workflow.steps.count

    # Replace workflow steps with something different
    @workflow.update_column(:start_step_id, nil)
    @workflow.steps.destroy_all
    Steps::Escalate.create!(workflow: @workflow, position: 0, title: "Escalate!")

    post workflow_restore_version_path(@workflow, @version)
    assert_redirected_to edit_workflow_path(@workflow)

    @workflow.reload
    assert_equal original_step_count, @workflow.steps.count
    restored_titles = @workflow.steps.pluck(:title)
    assert_includes restored_titles, "Start Question"
    assert_includes restored_titles, "All Done"
    assert_not_includes restored_titles, "Escalate!"
  end

  test "restore: increments version count after publishing a new version" do
    sign_in @editor
    WorkflowPublisher.publish(@workflow, @editor, changelog: "v2")

    assert_equal 2, @workflow.versions.count

    @workflow.update_column(:start_step_id, nil)
    @workflow.steps.destroy_all

    post workflow_restore_version_path(@workflow, @version)
    assert_redirected_to edit_workflow_path(@workflow)
    @workflow.reload
    assert_equal "Start Question", @workflow.steps.order(:position).first.title
  end
end
