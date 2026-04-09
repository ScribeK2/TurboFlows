require "test_helper"

class WorkflowVersionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "version-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Version Test Workflow",
      user: @user,
      graph_mode: false
    )
    @q1_step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "What?")
  end

  test "valid with all required attributes" do
    snapshot = [{ "id" => @q1_step.uuid, "type" => "question", "title" => "Q1", "question" => "What?" }]
    version = WorkflowVersion.new(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: snapshot,
      metadata_snapshot: { "title" => @workflow.title, "graph_mode" => @workflow.graph_mode },
      published_by: @user,
      published_at: Time.current
    )
    assert_predicate version, :valid?, version.errors.full_messages.join(", ")
  end

  test "invalid without workflow" do
    version = WorkflowVersion.new(
      version_number: 1,
      steps_snapshot: [],
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    assert_not version.valid?
    assert_includes version.errors[:workflow], "must exist"
  end

  test "invalid without version_number" do
    version = WorkflowVersion.new(
      workflow: @workflow,
      steps_snapshot: [],
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    assert_not version.valid?
    assert_includes version.errors[:version_number], "can't be blank"
  end

  test "invalid without published_by" do
    version = WorkflowVersion.new(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: [],
      metadata_snapshot: {},
      published_at: Time.current
    )
    assert_not version.valid?
    assert_includes version.errors[:published_by], "must exist"
  end

  test "invalid without published_at" do
    version = WorkflowVersion.new(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: [],
      metadata_snapshot: {},
      published_by: @user
    )
    assert_not version.valid?
    assert_includes version.errors[:published_at], "can't be blank"
  end

  test "version_number must be unique per workflow" do
    snapshot = [{ "id" => @q1_step.uuid, "type" => "question", "title" => "Q1", "question" => "What?" }]
    WorkflowVersion.create!(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: snapshot,
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    duplicate = WorkflowVersion.new(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: snapshot,
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:version_number], "has already been taken"
  end

  test "different workflows can have the same version_number" do
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: @user
    )
    WorkflowVersion.create!(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: [],
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    version = WorkflowVersion.new(
      workflow: other_workflow,
      version_number: 1,
      steps_snapshot: [],
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    assert_predicate version, :valid?
  end

  test "stores steps_snapshot as deep copy" do
    snapshot = [{ "id" => @q1_step.uuid, "type" => "question", "title" => "Q1", "question" => "What?" }]
    version = WorkflowVersion.create!(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: snapshot,
      metadata_snapshot: {},
      published_by: @user,
      published_at: Time.current
    )
    # Modify original workflow steps
    @q1_step.update!(title: "Changed")
    # Version snapshot should be unchanged
    version.reload
    assert_equal "question", version.steps_snapshot.first["type"]
    assert_equal "Q1", version.steps_snapshot.first["title"]
  end

  test "newest_first scope orders by version_number descending" do
    v1 = WorkflowVersion.create!(workflow: @workflow, version_number: 1, steps_snapshot: [], metadata_snapshot: {}, published_by: @user, published_at: 2.days.ago)
    v2 = WorkflowVersion.create!(workflow: @workflow, version_number: 2, steps_snapshot: [], metadata_snapshot: {}, published_by: @user, published_at: 1.day.ago)
    v3 = WorkflowVersion.create!(workflow: @workflow, version_number: 3, steps_snapshot: [], metadata_snapshot: {}, published_by: @user, published_at: Time.current)

    versions = @workflow.versions.newest_first.to_a
    assert_equal [v3, v2, v1], versions
  end
end
