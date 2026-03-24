require "test_helper"

class StepBuilderTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "step-builder-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Builder Test Workflow",
      user: @user,
      graph_mode: true
    )
  end

  test "creates steps with correct STI types and attributes" do
    steps_data = [
      { "id" => "uuid-1", "type" => "question", "title" => "Ask name",
        "question" => "What is your name?", "answer_type" => "text",
        "variable_name" => "name" },
      { "id" => "uuid-2", "type" => "action", "title" => "Look up account",
        "action_type" => "Instruction", "can_resolve" => false },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data)

    assert_equal 3, @workflow.steps.reload.count
    assert_instance_of Steps::Question, @workflow.steps.find_by(uuid: "uuid-1")
    assert_instance_of Steps::Action, @workflow.steps.find_by(uuid: "uuid-2")
  end

  test "creates transitions between steps" do
    steps_data = [
      { "id" => "uuid-1", "type" => "question", "title" => "Q1", "question" => "Ask?",
        "transitions" => [{ "target_uuid" => "uuid-2", "condition" => "yes", "label" => "Yes" }] },
      { "id" => "uuid-2", "type" => "action", "title" => "A1" },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data)

    source = @workflow.steps.find_by(uuid: "uuid-1")
    assert_equal 1, source.transitions.count
    assert_equal "yes", source.transitions.first.condition
  end

  test "sets start step from start_node_uuid" do
    steps_data = [
      { "id" => "uuid-1", "type" => "question", "title" => "Q1", "question" => "Ask?" },
      { "id" => "uuid-2", "type" => "action", "title" => "A1" },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data, start_node_uuid: "uuid-2")

    assert_equal "uuid-2", @workflow.reload.start_step.uuid
  end

  test "sets first step as start when start_node_uuid is nil" do
    steps_data = [
      { "id" => "uuid-1", "type" => "question", "title" => "Q1", "question" => "Ask?" },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data)

    assert_equal "uuid-1", @workflow.reload.start_step.uuid
  end

  test "replace mode destroys existing steps first" do
    Steps::Action.create!(workflow: @workflow, uuid: "old-uuid", position: 0, title: "Old")

    steps_data = [
      { "id" => "uuid-new", "type" => "question", "title" => "New", "question" => "Ask?" },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data, replace: true)

    assert_equal 2, @workflow.steps.reload.count
    assert @workflow.steps.find_by(uuid: "uuid-new")
  end

  test "assigns rich text fields" do
    steps_data = [
      { "id" => "uuid-1", "type" => "action", "title" => "Do thing",
        "instructions" => "<p>Do this</p>" },
      { "id" => "uuid-2", "type" => "message", "title" => "Show msg",
        "content" => "<p>Hello</p>" },
      { "id" => "uuid-3", "type" => "escalate", "title" => "Esc",
        "target_type" => "supervisor", "notes" => "<p>Urgent</p>" },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data)

    action = @workflow.steps.find_by(uuid: "uuid-1")
    assert_includes action.instructions.body.to_s, "Do this"

    message = @workflow.steps.find_by(uuid: "uuid-2")
    assert_includes message.content.body.to_s, "Hello"

    escalate = @workflow.steps.find_by(uuid: "uuid-3")
    assert_includes escalate.notes.body.to_s, "Urgent"
  end

  test "empty steps array is a no-op" do
    StepBuilder.call(@workflow, [])
    assert_equal 0, @workflow.steps.reload.count
  end

  test "all six STI types map correctly" do
    types = %w[question action message escalate resolve sub_flow]
    steps_data = types.each_with_index.map do |type, i|
      data = { "id" => "uuid-#{i}", "type" => type, "title" => "Step #{i}" }
      data["question"] = "Ask?" if type == "question"
      data["target_workflow_id"] = @workflow.id if type == "sub_flow"
      data
    end

    StepBuilder.call(@workflow, steps_data)

    assert_equal 6, @workflow.steps.reload.count
    assert_instance_of Steps::Question, @workflow.steps.find_by(uuid: "uuid-0")
    assert_instance_of Steps::Action, @workflow.steps.find_by(uuid: "uuid-1")
    assert_instance_of Steps::Message, @workflow.steps.find_by(uuid: "uuid-2")
    assert_instance_of Steps::Escalate, @workflow.steps.find_by(uuid: "uuid-3")
    assert_instance_of Steps::Resolve, @workflow.steps.find_by(uuid: "uuid-4")
    assert_instance_of Steps::SubFlow, @workflow.steps.find_by(uuid: "uuid-5")
  end

  test "build_attrs extracts position_x and position_y" do
    step_data = { "type" => "action", "title" => "A", "position_x" => 120, "position_y" => 240 }
    attrs = StepBuilder.build_attrs(step_data, 0)
    assert_equal 120, attrs[:position_x]
    assert_equal 240, attrs[:position_y]
  end

  test "build_attrs omits position_x and position_y when not in data" do
    step_data = { "type" => "action", "title" => "A" }
    attrs = StepBuilder.build_attrs(step_data, 0)
    assert_not attrs.key?(:position_x)
    assert_not attrs.key?(:position_y)
  end

  test "unknown step type defaults to Steps::Action" do
    steps_data = [
      { "id" => "uuid-1", "type" => "unknown_type", "title" => "Mystery" },
      { "id" => "uuid-r", "type" => "resolve", "title" => "Done" }
    ]

    StepBuilder.call(@workflow, steps_data)

    assert_instance_of Steps::Action, @workflow.steps.find_by(uuid: "uuid-1")
  end

  test "auto-creates sequential transitions when no explicit transitions provided" do
    steps_data = [
      { "type" => "question", "title" => "Q1", "id" => "uuid-1" },
      { "type" => "action", "title" => "A1", "id" => "uuid-2" },
      { "type" => "resolve", "title" => "Done", "id" => "uuid-3" }
    ]
    StepBuilder.call(@workflow, steps_data)
    steps = @workflow.steps.reload
    assert_equal 3, steps.count
    q1 = steps.find { |s| s.uuid == "uuid-1" }
    a1 = steps.find { |s| s.uuid == "uuid-2" }
    done = steps.find { |s| s.uuid == "uuid-3" }
    assert_equal 1, q1.transitions.count
    assert_equal a1, q1.transitions.first.target_step
    assert_equal 1, a1.transitions.count
    assert_equal done, a1.transitions.first.target_step
    assert_equal 0, done.transitions.count
  end

  test "raises error when no Resolve step in steps_data" do
    steps_data = [
      { "type" => "question", "title" => "Q1", "id" => "uuid-1" },
      { "type" => "action", "title" => "A1", "id" => "uuid-2" }
    ]
    assert_raises(ActiveRecord::RecordInvalid) do
      StepBuilder.call(@workflow, steps_data)
    end
  end
end
