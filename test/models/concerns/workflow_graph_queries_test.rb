require "test_helper"

class WorkflowGraphQueriesTest < ActiveSupport::TestCase
  setup do
    Bullet.enable = false if defined?(Bullet)

    @user = User.create!(
      email: "graph-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Graph Queries WF", user: @user)
    @step1 = Steps::Question.create!(
      workflow: @workflow, title: "Start", position: 0,
      answer_type: "yes_no", variable_name: "start_q"
    )
    @step2 = Steps::Action.create!(
      workflow: @workflow, title: "Middle", position: 1,
      action_type: "Instruction"
    )
    @step3 = Steps::Resolve.create!(
      workflow: @workflow, title: "End", position: 2,
      resolution_type: "success"
    )
    Transition.create!(step: @step1, target_step: @step2, position: 0)
    Transition.create!(step: @step2, target_step: @step3, position: 0)
    @workflow.update!(start_step: @step1)
  end

  teardown do
    Bullet.enable = true if defined?(Bullet)
  end

  test "graph_mode? always returns true" do
    assert_predicate @workflow, :graph_mode?
  end

  test "linear_mode? always returns false" do
    refute_predicate @workflow, :linear_mode?
  end

  test "graph_steps returns hash keyed by UUID" do
    graph = @workflow.graph_steps
    assert_instance_of Hash, graph
    assert_equal 3, graph.size
    assert_equal @step1, graph[@step1.uuid]
    assert_equal @step2, graph[@step2.uuid]
    assert_equal @step3, graph[@step3.uuid]
  end

  test "graph_steps includes transitions" do
    graph = @workflow.graph_steps
    step1_from_graph = graph[@step1.uuid]
    assert_equal 1, step1_from_graph.transitions.size
    assert_equal @step2.id, step1_from_graph.transitions.first.target_step_id
  end

  test "start_node returns start_step when set" do
    assert_equal @step1, @workflow.start_node
  end

  test "start_node falls back to first step when start_step is nil" do
    @workflow.update_columns(start_step_id: nil)
    @workflow.reload
    assert_equal @step1, @workflow.start_node
  end

  test "terminal_nodes returns steps without outgoing transitions" do
    terminals = @workflow.terminal_nodes
    assert_includes terminals, @step3
    refute_includes terminals, @step1
    refute_includes terminals, @step2
  end

  test "terminal_nodes returns empty for workflow where all steps have transitions" do
    Transition.create!(step: @step3, target_step: @step1, position: 0)
    assert_empty @workflow.terminal_nodes
  end
end
