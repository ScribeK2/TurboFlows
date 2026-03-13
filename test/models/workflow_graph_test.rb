require "test_helper"

class WorkflowGraphTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:one)
  end

  test "graph_mode? returns correct value" do
    linear_workflow = Workflow.create!(
      title: "Linear",
      user: @user,
      graph_mode: false,
      steps: []
    )

    graph_workflow = Workflow.create!(
      title: "Graph",
      user: @user,
      graph_mode: true,
      steps: []
    )

    assert_not linear_workflow.graph_mode?
    assert_predicate graph_workflow, :graph_mode?
    assert_predicate linear_workflow, :linear_mode?
    assert_not graph_workflow.linear_mode?
  end

  test "graph_steps returns hash keyed by UUID" do
    workflow = Workflow.create!(
      title: "Graph Steps Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'uuid-1',
      steps: [
        { 'id' => 'uuid-1', 'type' => 'action', 'title' => 'Step 1', 'transitions' => [{ 'target_uuid' => 'uuid-2' }] },
        { 'id' => 'uuid-2', 'type' => 'action', 'title' => 'Step 2', 'transitions' => [] }
      ]
    )

    graph_steps = workflow.graph_steps

    assert_instance_of Hash, graph_steps
    assert_equal 2, graph_steps.length
    assert graph_steps.key?('uuid-1')
    assert graph_steps.key?('uuid-2')
    assert_equal 'Step 1', graph_steps['uuid-1']['title']
  end

  test "start_node returns correct step" do
    workflow = Workflow.create!(
      title: "Start Node Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'uuid-2',
      steps: [
        { 'id' => 'uuid-2', 'type' => 'question', 'title' => 'Start Step', 'question' => 'Begin?', 'transitions' => [{ 'target_uuid' => 'uuid-1' }] },
        { 'id' => 'uuid-1', 'type' => 'action', 'title' => 'Not Start', 'transitions' => [] }
      ]
    )

    start = workflow.start_node

    assert_not_nil start
    assert_equal 'uuid-2', start['id']
    assert_equal 'Start Step', start['title']
  end

  test "start_node defaults to first step if not set" do
    workflow = Workflow.create!(
      title: "Default Start Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: nil,
      steps: [
        { 'id' => 'uuid-1', 'type' => 'action', 'title' => 'First Step', 'transitions' => [{ 'target_uuid' => 'uuid-2' }] },
        { 'id' => 'uuid-2', 'type' => 'action', 'title' => 'Second Step', 'transitions' => [] }
      ]
    )

    start = workflow.start_node

    assert_not_nil start
    assert_equal 'uuid-1', start['id']
  end

  test "terminal_nodes returns steps without transitions in graph mode" do
    workflow = Workflow.create!(
      title: "Terminal Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'question', 'title' => 'Start', 'question' => 'Which path?', 'transitions' => [{ 'target_uuid' => 'b' }, { 'target_uuid' => 'c' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'End 1', 'transitions' => [] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'End 2', 'transitions' => [] }
      ]
    )

    terminals = workflow.terminal_nodes

    assert_equal 2, terminals.length
    assert(terminals.all? { |t| t['transitions'].empty? })
  end

  test "terminal_nodes returns last step in linear mode" do
    workflow = Workflow.create!(
      title: "Linear Terminal Test",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'First' },
        { 'id' => 'b', 'type' => 'action', 'title' => 'Last' }
      ]
    )

    terminals = workflow.terminal_nodes

    assert_equal 1, terminals.length
    assert_equal 'Last', terminals[0]['title']
  end

  test "transitions_from returns step transitions" do
    workflow = Workflow.create!(
      title: "Transitions Test",
      user: @user,
      graph_mode: true,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'Start', 'transitions' => [
          { 'target_uuid' => 'b', 'condition' => "x == 1" },
          { 'target_uuid' => 'c' }
        ] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'B', 'transitions' => [] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'C', 'transitions' => [] }
      ]
    )

    transitions = workflow.transitions_from('a')

    assert_equal 2, transitions.length
    assert_equal 'b', transitions[0]['target_uuid']
    assert_equal "x == 1", transitions[0]['condition']
  end

  test "steps_leading_to returns source steps" do
    workflow = Workflow.create!(
      title: "Leading To Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'start',
      steps: [
        { 'id' => 'start', 'type' => 'question', 'title' => 'Start', 'question' => 'Which path?', 'transitions' => [{ 'target_uuid' => 'a' }, { 'target_uuid' => 'b' }] },
        { 'id' => 'a', 'type' => 'action', 'title' => 'A', 'transitions' => [{ 'target_uuid' => 'c' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'B', 'transitions' => [{ 'target_uuid' => 'c' }] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'Target', 'transitions' => [] }
      ]
    )

    sources = workflow.steps_leading_to('c')

    assert_equal 2, sources.length
    titles = sources.map { |s| s['title'] }

    assert_includes titles, 'A'
    assert_includes titles, 'B'
  end

  test "add_transition creates new transition" do
    # Start in linear mode to bypass reachability validation, then switch to graph mode
    workflow = Workflow.create!(
      title: "Add Transition Test",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'A' },
        { 'id' => 'b', 'type' => 'action', 'title' => 'B' }
      ]
    )

    # Switch to graph mode and add transitions
    workflow.graph_mode = true
    workflow.steps[0]['transitions'] = []
    workflow.steps[1]['transitions'] = []

    result = workflow.add_transition('a', 'b', condition: "x == 1")

    assert result
    assert_equal 1, workflow.steps[0]['transitions'].length
    assert_equal 'b', workflow.steps[0]['transitions'][0]['target_uuid']
    assert_equal "x == 1", workflow.steps[0]['transitions'][0]['condition']
  end

  test "add_transition fails in linear mode" do
    workflow = Workflow.create!(
      title: "Linear Add Test",
      user: @user,
      graph_mode: false,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'A' },
        { 'id' => 'b', 'type' => 'action', 'title' => 'B' }
      ]
    )

    result = workflow.add_transition('a', 'b')

    assert_not result
  end

  test "add_transition prevents duplicates" do
    workflow = Workflow.create!(
      title: "Duplicate Test",
      user: @user,
      graph_mode: true,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'A', 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'B', 'transitions' => [] }
      ]
    )

    result = workflow.add_transition('a', 'b')

    assert_not result
    assert_equal 1, workflow.steps[0]['transitions'].length
  end

  test "remove_transition removes existing transition" do
    workflow = Workflow.create!(
      title: "Remove Transition Test",
      user: @user,
      graph_mode: true,
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'A', 'transitions' => [{ 'target_uuid' => 'b' }, { 'target_uuid' => 'c' }] },
        { 'id' => 'b', 'type' => 'action', 'title' => 'B', 'transitions' => [] },
        { 'id' => 'c', 'type' => 'action', 'title' => 'C', 'transitions' => [] }
      ]
    )

    result = workflow.remove_transition('a', 'b')

    assert result
    assert_equal 1, workflow.steps[0]['transitions'].length
    assert_equal 'c', workflow.steps[0]['transitions'][0]['target_uuid']
  end

  test "subflow_steps returns sub_flow type steps" do
    target = Workflow.create!(title: "Target", user: @user, status: 'published', steps: [])

    workflow = Workflow.create!(
      title: "Subflow Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'action', 'title' => 'Action', 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'sub_flow', 'title' => 'Call Sub', 'target_workflow_id' => target.id, 'transitions' => [{ 'target_uuid' => 'c' }] },
        { 'id' => 'c', 'type' => 'sub_flow', 'title' => 'Call Sub 2', 'target_workflow_id' => target.id, 'transitions' => [] }
      ]
    )

    subflows = workflow.subflow_steps

    assert_equal 2, subflows.length
    assert(subflows.all? { |s| s['type'] == 'sub_flow' })
  end

  test "referenced_workflow_ids returns unique workflow IDs" do
    target1 = Workflow.create!(title: "Target 1", user: @user, status: 'published', steps: [])
    target2 = Workflow.create!(title: "Target 2", user: @user, status: 'published', steps: [])

    workflow = Workflow.create!(
      title: "References Test",
      user: @user,
      graph_mode: true,
      start_node_uuid: 'a',
      steps: [
        { 'id' => 'a', 'type' => 'sub_flow', 'title' => 'Sub 1', 'target_workflow_id' => target1.id, 'transitions' => [{ 'target_uuid' => 'b' }] },
        { 'id' => 'b', 'type' => 'sub_flow', 'title' => 'Sub 2', 'target_workflow_id' => target2.id, 'transitions' => [{ 'target_uuid' => 'c' }] },
        { 'id' => 'c', 'type' => 'sub_flow', 'title' => 'Sub 3', 'target_workflow_id' => target1.id, 'transitions' => [] }
      ]
    )

    ids = workflow.referenced_workflow_ids

    assert_equal 2, ids.length
    assert_includes ids, target1.id
    assert_includes ids, target2.id
  end

  test "validates graph structure in graph mode with AR steps" do
    workflow = Workflow.create!(title: "Invalid Graph", user: @user, graph_mode: true, status: "published")
    # Single step with no transitions = dead end in published graph mode
    step_a = Steps::Action.create!(workflow: workflow, position: 0, uuid: "a", title: "A")
    step_b = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "B")
    # A -> B exists, but B is unreachable from A only if graph is disconnected
    # Actually: A has a transition to B, but B has no outgoing transitions AND A is a dead end too
    # Simplest: create two disconnected nodes - A has no transitions (dead end)
    # and B is unreachable from start
    workflow.update_column(:start_step_id, step_a.id)

    workflow.reload
    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("dead end") || e.include?("unreachable") || e.include?("reachable") },
      "Expected graph validation error, got: #{workflow.errors[:steps].inspect}")
  end

  test "validates subflow references with AR steps" do
    workflow = Workflow.create!(title: "Invalid Subflow", user: @user)
    # Use save with validate: false to bypass belongs_to validation
    step = Steps::SubFlow.new(workflow: workflow, position: 0, uuid: "a", title: "Bad Sub", sub_flow_workflow_id: 999_999)
    step.save!(validate: false)

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("does not exist") })
  end

  test "validates self-referencing subflow with AR steps" do
    workflow = Workflow.create!(title: "Self Reference", user: @user, status: "published")
    Steps::SubFlow.create!(workflow: workflow, position: 0, uuid: "a", title: "Self", sub_flow_workflow_id: workflow.id)

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("cannot reference itself") })
  end
end
