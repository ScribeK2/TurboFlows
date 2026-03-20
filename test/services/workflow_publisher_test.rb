require "test_helper"

class WorkflowPublisherTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "publisher-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Publishable Workflow",
      description: "A workflow to publish",
      user: @user,
      graph_mode: true
    )
    @q_step = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Q1", question: "What?", variable_name: "q1"
    )
    @r_step = Steps::Resolve.create!(
      workflow: @workflow, position: 1, title: "Done", resolution_type: "success"
    )
    Transition.create!(step: @q_step, target_step: @r_step, position: 0)
    @workflow.update_column(:start_step_id, @q_step.id)
  end

  test "publishes a workflow and creates a version" do
    result = WorkflowPublisher.publish(@workflow, @user)

    assert result.success?, result.error
    version = result.version
    assert_equal 1, version.version_number
    assert_equal "Q1", version.steps_snapshot.first["title"]
    assert_equal @user, version.published_by
    assert_not_nil version.published_at
  end

  test "snapshots metadata correctly" do
    result = WorkflowPublisher.publish(@workflow, @user)

    metadata = result.version.metadata_snapshot
    assert_equal "Publishable Workflow", metadata["title"]
    assert_equal true, metadata["graph_mode"]
    assert_equal @q_step.uuid, metadata["start_node_uuid"]
  end

  test "sets published_version_id on workflow" do
    result = WorkflowPublisher.publish(@workflow, @user)

    @workflow.reload
    assert_equal result.version, @workflow.published_version
  end

  test "increments version_number on successive publishes" do
    WorkflowPublisher.publish(@workflow, @user)
    result = WorkflowPublisher.publish(@workflow, @user, changelog: "Updated steps")

    assert_equal 2, result.version.version_number
  end

  test "stores changelog" do
    result = WorkflowPublisher.publish(@workflow, @user, changelog: "Initial release")

    assert_equal "Initial release", result.version.changelog
  end

  test "fails if workflow has no steps" do
    empty_workflow = Workflow.create!(title: "Empty", user: @user, graph_mode: true)

    result = WorkflowPublisher.publish(empty_workflow, @user)

    assert_not result.success?
    assert_match(/no steps/i, result.error)
  end

  test "fails if workflow has validation errors in graph mode" do
    # Create a step with a transition to a nonexistent target
    r_step = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "End")
    # Create transition to non-existent step to trigger graph validation failure
    Transition.create!(step: @q_step, target_step: r_step, position: 0)
    # Add an orphaned step with no incoming transitions and no outgoing
    orphan = Steps::Action.create!(workflow: @workflow, position: 2, title: "Orphan")

    result = WorkflowPublisher.publish(@workflow, @user)

    assert_not result.success?
    assert result.error.present?
  end

  test "does not create version on failure" do
    empty_workflow = Workflow.create!(title: "Empty", user: @user, graph_mode: true)

    assert_no_difference "WorkflowVersion.count" do
      WorkflowPublisher.publish(empty_workflow, @user)
    end
  end

  test "published_version points to latest version" do
    WorkflowPublisher.publish(@workflow, @user)

    # Add a new step between Q1 and Done, rewire transitions for v2
    new_step = Steps::Action.create!(workflow: @workflow, position: 1, title: "New Step")
    @r_step.update!(position: 2)
    # Remove old Q1->Done transition and add Q1->New->Done
    @q_step.transitions.destroy_all
    Transition.create!(step: @q_step, target_step: new_step, position: 0)
    Transition.create!(step: new_step, target_step: @r_step, position: 0)
    result = WorkflowPublisher.publish(@workflow, @user, changelog: "v2")

    @workflow.reload
    assert_equal 2, @workflow.published_version.version_number
    assert_equal "New Step", @workflow.published_version.steps_snapshot[1]["title"]
  end
end
