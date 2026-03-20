require "test_helper"

class StepSyncerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "step-syncer-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Syncer Test Workflow",
      user: @user,
      graph_mode: true,
      status: "draft"
    )
  end

  test "creates new steps from incoming data" do
    incoming = [
      { "id" => "new-uuid", "type" => "action", "title" => "New Action" }
    ]

    result = StepSyncer.call(@workflow, incoming)

    assert result.success?
    assert_equal 1, @workflow.steps.reload.count
    assert_equal "new-uuid", @workflow.steps.first.uuid
  end

  test "updates existing steps by UUID match" do
    step = Steps::Action.create!(workflow: @workflow, uuid: "existing", position: 0, title: "Old")

    incoming = [
      { "id" => "existing", "type" => "action", "title" => "Updated" }
    ]

    StepSyncer.call(@workflow, incoming)

    assert_equal "Updated", step.reload.title
  end

  test "deletes steps not in incoming set" do
    Steps::Action.create!(workflow: @workflow, uuid: "keep", position: 0, title: "Keep")
    Steps::Action.create!(workflow: @workflow, uuid: "remove", position: 1, title: "Remove")

    incoming = [
      { "id" => "keep", "type" => "action", "title" => "Keep" }
    ]

    StepSyncer.call(@workflow, incoming)

    assert_equal 1, @workflow.steps.reload.count
    assert_equal "keep", @workflow.steps.first.uuid
  end

  test "reconciles transitions" do
    q = Steps::Question.create!(workflow: @workflow, uuid: "q1", position: 0, title: "Q1", question: "Ask?")
    a = Steps::Action.create!(workflow: @workflow, uuid: "a1", position: 1, title: "A1")
    a2 = Steps::Action.create!(workflow: @workflow, uuid: "a2", position: 2, title: "A2")
    Transition.create!(step: q, target_step: a, condition: "old", position: 0)

    incoming = [
      { "id" => "q1", "type" => "question", "title" => "Q1", "question" => "Ask?",
        "transitions" => [{ "target_uuid" => "a2", "condition" => "new" }] },
      { "id" => "a1", "type" => "action", "title" => "A1" },
      { "id" => "a2", "type" => "action", "title" => "A2" }
    ]

    StepSyncer.call(@workflow, incoming)

    q.reload
    assert_equal 1, q.transitions.count
    assert_equal "new", q.transitions.first.condition
    assert_equal a2.id, q.transitions.first.target_step_id
  end

  test "sets start step" do
    incoming = [
      { "id" => "uuid-1", "type" => "action", "title" => "A1" },
      { "id" => "uuid-2", "type" => "action", "title" => "A2" }
    ]

    StepSyncer.call(@workflow, incoming, start_node_uuid: "uuid-2")

    assert_equal "uuid-2", @workflow.reload.start_step.uuid
  end

  test "returns success with lock_version" do
    result = StepSyncer.call(@workflow, [{ "id" => "u1", "type" => "action", "title" => "A" }])

    assert result.success?
    assert result.lock_version.is_a?(Integer)
  end

  test "round-trips position_x and position_y" do
    incoming = [
      { "id" => "pos-1", "type" => "action", "title" => "A1", "position_x" => 100, "position_y" => 200 },
      { "id" => "pos-2", "type" => "action", "title" => "A2" }
    ]

    StepSyncer.call(@workflow, incoming)

    s1 = @workflow.steps.find_by(uuid: "pos-1")
    s2 = @workflow.steps.find_by(uuid: "pos-2")
    assert_equal 100, s1.position_x
    assert_equal 200, s1.position_y
    assert_nil s2.position_x
    assert_nil s2.position_y
  end

  test "updates position_x and position_y on existing steps" do
    Steps::Action.create!(workflow: @workflow, uuid: "existing-pos", position: 0, title: "A1")

    incoming = [
      { "id" => "existing-pos", "type" => "action", "title" => "A1", "position_x" => 300, "position_y" => 400 }
    ]

    StepSyncer.call(@workflow, incoming)

    step = @workflow.steps.find_by(uuid: "existing-pos")
    assert_equal 300, step.position_x
    assert_equal 400, step.position_y
  end

  test "accepts question without question text (validated on publish only)" do
    incoming = [
      { "id" => "u1", "type" => "question", "title" => "Q" }
    ]

    result = StepSyncer.call(@workflow, incoming)

    # Question text validation only runs on :publish context
    assert result.success?
    assert_equal 1, @workflow.steps.reload.count
  end
end
