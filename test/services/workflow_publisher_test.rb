require "test_helper"

class WorkflowPublisherTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "publisher-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @step_uuid = SecureRandom.uuid
    @workflow = Workflow.create!(
      title: "Publishable Workflow",
      description: "A workflow to publish",
      user: @user,
      graph_mode: true,
      start_node_uuid: @step_uuid,
      steps: [
        { "id" => @step_uuid, "type" => "question", "title" => "Q1", "question" => "What?" }
      ]
    )
  end

  test "publishes a workflow and creates a version" do
    result = WorkflowPublisher.publish(@workflow, @user)

    assert result.success?, result.error
    version = result.version
    assert_equal 1, version.version_number
    assert_equal @workflow.steps, version.steps_snapshot
    assert_equal @user, version.published_by
    assert_not_nil version.published_at
  end

  test "snapshots metadata correctly" do
    result = WorkflowPublisher.publish(@workflow, @user)

    metadata = result.version.metadata_snapshot
    assert_equal "Publishable Workflow", metadata["title"]
    assert_equal "A workflow to publish", metadata["description"]
    assert_equal true, metadata["graph_mode"]
    assert_equal @step_uuid, metadata["start_node_uuid"]
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
    @workflow.update_columns(steps: nil)
    @workflow.reload

    result = WorkflowPublisher.publish(@workflow, @user)

    assert_not result.success?
    assert_match(/no steps/i, result.error)
  end

  test "fails if workflow has validation errors in graph mode" do
    # Create a workflow with graph validation issues (broken transition target)
    orphan_uuid = SecureRandom.uuid
    @workflow.assign_attributes(
      steps: [
        { "id" => @step_uuid, "type" => "question", "title" => "Q1",
          "transitions" => [{ "target_uuid" => "nonexistent" }] },
        { "id" => orphan_uuid, "type" => "resolve", "title" => "End" }
      ]
    )
    @workflow.save!(validate: false)
    @workflow.reload

    result = WorkflowPublisher.publish(@workflow, @user)

    assert_not result.success?
    assert result.error.present?
  end

  test "does not create version on failure" do
    @workflow.update_columns(steps: nil)
    @workflow.reload

    assert_no_difference "WorkflowVersion.count" do
      WorkflowPublisher.publish(@workflow, @user)
    end
  end

  test "published_version points to latest version" do
    WorkflowPublisher.publish(@workflow, @user)
    # Change steps
    new_uuid = SecureRandom.uuid
    @workflow.update!(steps: [
      { "id" => new_uuid, "type" => "action", "title" => "New Step" }
    ], graph_mode: false)
    result = WorkflowPublisher.publish(@workflow, @user, changelog: "v2")

    @workflow.reload
    assert_equal 2, @workflow.published_version.version_number
    assert_equal "New Step", @workflow.published_version.steps_snapshot.first["title"]
  end
end
