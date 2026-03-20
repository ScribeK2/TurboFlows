require "test_helper"

class WorkflowGraphConverterTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:one)
  end

  test "converts simple linear workflow to graph" do
    workflow = Workflow.create!(title: "Linear to Graph", user: @user, graph_mode: false)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, uuid: "a", title: "Q1", question: "Test?")
    a_step = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "A1")
    end_step = Steps::Action.create!(workflow: workflow, position: 2, uuid: "c", title: "End")

    converter = WorkflowGraphConverter.new(workflow)
    assert converter.convert

    # First step should transition to second
    q_transitions = q_step.transitions.reload
    assert_equal 1, q_transitions.length
    assert_equal a_step, q_transitions.first.target_step

    # Second step should transition to third
    a_transitions = a_step.transitions.reload
    assert_equal 1, a_transitions.length
    assert_equal end_step, a_transitions.first.target_step

    # Last step should have no transitions (terminal)
    assert_equal 0, end_step.transitions.reload.length
  end

  test "validates converted graph" do
    workflow = Workflow.create!(title: "Valid Conversion", user: @user, graph_mode: false)

    Steps::Action.create!(workflow: workflow, position: 0, uuid: "a", title: "Start")
    Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "End")

    converter = WorkflowGraphConverter.new(workflow)

    assert_predicate converter, :valid_for_conversion?
    assert_empty converter.errors
  end

  test "returns true for already converted workflow with transitions" do
    workflow = Workflow.create!(title: "Already Graph", user: @user)

    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "a", title: "Start")
    step2 = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "End")
    Transition.create!(step: step1, target_step: step2, position: 0)
    workflow.update_column(:start_step_id, step1.id)

    converter = WorkflowGraphConverter.new(workflow)
    assert converter.convert
  end

  test "handles jumps in conversion" do
    workflow = Workflow.create!(title: "Jumps Conversion", user: @user, graph_mode: false)

    q_step = Steps::Question.create!(
      workflow: workflow, position: 0, uuid: "a", title: "Q1", question: "Skip?",
      variable_name: "skip", jumps: [{ "condition" => "yes", "next_step_id" => "c" }]
    )
    Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "Normal")
    skip_target = Steps::Action.create!(workflow: workflow, position: 2, uuid: "c", title: "Skip Target")

    converter = WorkflowGraphConverter.new(workflow)
    assert converter.convert

    # First step should have jump transition to skip_target
    q_transitions = q_step.transitions.reload
    assert q_transitions.any? { |t| t.target_step == skip_target }
  end

  test "preserves step data during conversion" do
    workflow = Workflow.create!(title: "Data Preservation", user: @user, graph_mode: false)

    q_step = Steps::Question.create!(
      workflow: workflow, position: 0, uuid: "a", title: "Q1",
      question: "What?", answer_type: "text", variable_name: "response"
    )
    a_step = Steps::Action.create!(
      workflow: workflow, position: 1, uuid: "b", title: "A1", action_type: "Email"
    )

    converter = WorkflowGraphConverter.new(workflow)
    assert converter.convert

    # Verify step data unchanged
    q_step.reload
    assert_equal "What?", q_step.question
    assert_equal "text", q_step.answer_type
    assert_equal "response", q_step.variable_name

    a_step.reload
    assert_equal "Email", a_step.action_type
  end
end
