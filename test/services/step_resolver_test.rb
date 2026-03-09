require "test_helper"

class StepResolverTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:one)
  end

  test "resolves next step via transitions" do
    workflow = Workflow.create!(
      title: "Sequential Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'Test?', 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'A1', 'instructions' => 'Do something', 'transitions' => [{ 'target_uuid' => 'c' }] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'A2', 'instructions' => 'Done', 'transitions' => [] }
      ]
    )

    resolver = StepResolver.new(workflow)
    step = workflow.steps[0]

    next_uuid = resolver.resolve_next(step, {})

    assert_equal 'b', next_uuid
  end

  test "resolves next step in graph mode" do
    workflow = Workflow.create!(
      title: "Graph Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'Test?', 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'A1', 'instructions' => 'Do something', 'transitions' => [{ 'target_uuid' => 'c' }] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'A2', 'instructions' => 'Done', 'transitions' => [] }
      ]
    )

    resolver = StepResolver.new(workflow)
    step = workflow.steps[0]

    next_uuid = resolver.resolve_next(step, {})

    assert_equal 'b', next_uuid
  end

  test "resolves conditional transition in graph mode" do
    workflow = Workflow.create!(
      title: "Conditional Graph Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'Yes or no?', 'variable_name' => 'answer', 'transitions' => [
          { 'target_uuid' => 'b', 'condition' => "answer == 'yes'" },
          { 'target_uuid' => 'c', 'condition' => "answer == 'no'" },
          { 'target_uuid' => 'd' } # Default
        ] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'Yes Path', 'transitions' => [] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'No Path', 'transitions' => [] },
        { 'id' => 'd', 'type' => 'action', 'title' => 'Default Path', 'transitions' => [] }
      ]
    )

    resolver = StepResolver.new(workflow)
    step = workflow.steps[0]

    # Test yes path
    next_uuid = resolver.resolve_next(step, { 'answer' => 'yes' })

    assert_equal 'b', next_uuid

    # Test no path
    next_uuid = resolver.resolve_next(step, { 'answer' => 'no' })

    assert_equal 'c', next_uuid

    # Test default path
    next_uuid = resolver.resolve_next(step, { 'answer' => 'maybe' })

    assert_equal 'd', next_uuid
  end

  test "identifies terminal nodes" do
    workflow = Workflow.create!(
      title: "Terminal Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Q1', 'question' => 'Test?', 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'End', 'transitions' => [] }
      ]
    )

    resolver = StepResolver.new(workflow)

    assert_not resolver.terminal?(workflow.steps[0])
    assert resolver.terminal?(workflow.steps[1])
  end

  test "returns subflow marker for sub_flow steps" do
    target_workflow = Workflow.create!(
      title: "Target Workflow",
      user: @user,
      status: 'published',
      steps: [
        { 'id' => 'x', 'type' => 'action', 'title' => 'Sub Action', 'instructions' => 'Do sub task' }
      ]
    )

    workflow = Workflow.create!(
      title: "Parent Workflow",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'sub_flow', 'title' => 'Call Sub', 'target_workflow_id' => target_workflow.id, 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'After Sub', 'transitions' => [] }
      ]
    )

    resolver = StepResolver.new(workflow)
    step = workflow.steps[0]

    result = resolver.resolve_next(step, {})

    assert_instance_of StepResolver::SubflowMarker, result
    assert_equal target_workflow.id, result.target_workflow_id
    assert_equal 'a', result.step_uuid
  end

  test "finds start step" do
    workflow = Workflow.create!(
      title: "Start Step Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'b',
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'Not Start', 'transitions' => [] },
        { 'id' => 'b', 'type' => 'question', 'title' => 'Start', 'question' => 'Begin?', 'transitions' => [{ 'target_uuid' => 'a' }] }
      ]
    )

    resolver = StepResolver.new(workflow)
    start = resolver.start_step

    assert_equal 'b', start['id']
    assert_equal 'Start', start['title']
  end

  # ============================================================================
  # ActiveRecord Step tests (new path)
  # ============================================================================

  test "AR: resolves conditional transition with Step objects" do
    workflow = Workflow.create!(title: "AR Test", user: @user, graph_mode: true)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, title: "Q1", question: "Yes or No?", variable_name: "answer")
    a_step = Steps::Action.create!(workflow: workflow, position: 1, title: "A1")
    r_step = Steps::Resolve.create!(workflow: workflow, position: 2, title: "Done", resolution_type: "success")

    Transition.create!(step: q_step, target_step: a_step, condition: "answer == yes", position: 0)
    Transition.create!(step: q_step, target_step: r_step, position: 1)
    Transition.create!(step: a_step, target_step: r_step, position: 0)

    workflow.update_column(:start_step_id, q_step.id)

    resolver = StepResolver.new(workflow)

    # Conditional match
    assert_equal a_step, resolver.resolve_next(q_step, { "answer" => "yes" })
    # Default fallback
    assert_equal r_step, resolver.resolve_next(q_step, { "answer" => "no" })
    # Terminal
    assert_nil resolver.resolve_next(r_step, {})
  end

  test "AR: detects terminal steps" do
    workflow = Workflow.create!(title: "AR Terminal", user: @user, graph_mode: true)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, title: "Q1", question: "Test?")
    r_step = Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done")
    Transition.create!(step: q_step, target_step: r_step, position: 0)

    resolver = StepResolver.new(workflow)
    assert_not resolver.terminal?(q_step)
    assert resolver.terminal?(r_step)
  end

  test "AR: returns SubflowMarker for sub_flow step" do
    target_wf = Workflow.create!(title: "Child", user: @user, status: "published")
    workflow = Workflow.create!(title: "Parent", user: @user, graph_mode: true)
    sf_step = Steps::SubFlow.create!(workflow: workflow, position: 0, title: "SF1", sub_flow_workflow_id: target_wf.id)

    resolver = StepResolver.new(workflow)
    result = resolver.resolve_next(sf_step, {})

    assert_instance_of StepResolver::SubflowMarker, result
    assert_equal target_wf.id, result.target_workflow_id
    assert_equal sf_step.uuid, result.step_uuid
  end

  test "AR: finds start step from ActiveRecord" do
    workflow = Workflow.create!(title: "AR Start", user: @user, graph_mode: true)
    q_step = Steps::Question.create!(workflow: workflow, position: 0, title: "Start", question: "Begin?")
    workflow.update_column(:start_step_id, q_step.id)

    resolver = StepResolver.new(workflow.reload)
    assert_equal q_step, resolver.start_step
  end
end
