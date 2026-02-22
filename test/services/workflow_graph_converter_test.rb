require "test_helper"

class WorkflowGraphConverterTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:one)
  end

  test "converts simple linear workflow to graph" do
    workflow = Workflow.create!(
      title: "Linear to Graph",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'Test?' },
        { 'id' => 'b', 'type' => 'action', 'title' => 'A1', 'instructions' => 'Do something' },
        { 'id' => 'c', 'type' => 'action', 'title' => 'End', 'instructions' => 'Done' }
      ]
    )

    converter = WorkflowGraphConverter.new(workflow)
    converted_steps = converter.convert

    assert_not_nil converted_steps
    assert_equal 3, converted_steps.length

    # First step should transition to second
    assert_equal 1, converted_steps[0]['transitions'].length
    assert_equal 'b', converted_steps[0]['transitions'][0]['target_uuid']

    # Second step should transition to third
    assert_equal 1, converted_steps[1]['transitions'].length
    assert_equal 'c', converted_steps[1]['transitions'][0]['target_uuid']

    # Last step should have no transitions (terminal)
    assert_equal 0, converted_steps[2]['transitions'].length
  end

  test "validates converted graph" do
    workflow = Workflow.create!(
      title: "Valid Conversion",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'Start', 'instructions' => 'Begin' },
        { 'id' => 'b', 'type' => 'action', 'title' => 'End', 'instructions' => 'Finish' }
      ]
    )

    converter = WorkflowGraphConverter.new(workflow)

    assert_predicate converter, :valid_for_conversion?
    assert_empty converter.errors
  end

  test "returns nil for already graph mode workflow" do
    workflow = Workflow.create!(
      title: "Already Graph",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'Only Step', 'transitions' => [] }
      ]
    )

    converter = WorkflowGraphConverter.new(workflow)
    result = converter.convert

    # Should return the existing steps unchanged
    assert_equal workflow.steps, result
  end

  test "handles jumps in conversion" do
    workflow = Workflow.create!(
      title: "Jumps Conversion",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'Skip?', 'variable_name' => 'skip', 'jumps' => [
          { 'condition' => 'yes', 'next_step_id' => 'c' }
        ] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'Normal', 'instructions' => 'Normal path' },
        { 'id' => 'c', 'type' => 'action', 'title' => 'Skip Target', 'instructions' => 'Jumped here' }
      ]
    )

    converter = WorkflowGraphConverter.new(workflow)
    converted_steps = converter.convert

    assert_not_nil converted_steps

    # First step should have jump transition
    first_step = converted_steps[0]

    assert(first_step['transitions'].any? { |t| t['target_uuid'] == 'c' })
  end

  test "preserves step data during conversion" do
    workflow = Workflow.create!(
      title: "Data Preservation",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'What?', 'answer_type' => 'text', 'variable_name' => 'response' },
        { 'id' => 'b', 'type' => 'action', 'title' => 'A1', 'instructions' => 'Do it', 'action_type' => 'Email' }
      ]
    )

    converter = WorkflowGraphConverter.new(workflow)
    converted_steps = converter.convert

    # Check question step data preserved
    q_step = converted_steps[0]

    assert_equal 'question', q_step['type']
    assert_equal 'What?', q_step['question']
    assert_equal 'text', q_step['answer_type']
    assert_equal 'response', q_step['variable_name']

    # Check action step data preserved
    a_step = converted_steps[1]

    assert_equal 'action', a_step['type']
    assert_equal 'Do it', a_step['instructions']
    assert_equal 'Email', a_step['action_type']
  end
end
