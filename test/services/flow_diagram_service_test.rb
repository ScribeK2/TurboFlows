require "test_helper"

class FlowDiagramServiceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "diagram-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  test "returns empty array for workflow with no steps" do
    workflow = Workflow.create!(title: "Empty", user: @user)
    result = FlowDiagramService.call(workflow)
    assert_equal [], result
  end

  test "disconnected steps without start_step uses position fallback" do
    workflow = Workflow.create!(title: "No Start", user: @user)
    s1 = Steps::Action.create!(workflow: workflow, position: 0, title: "First")
    s2 = Steps::Action.create!(workflow: workflow, position: 1, title: "Second")
    s3 = Steps::Action.create!(workflow: workflow, position: 2, title: "Third")

    result = FlowDiagramService.call(workflow)

    # Without transitions, BFS starts at first by position, rest are orphans
    assert_equal 2, result.size
    assert_equal [s1], result[0]
    assert_includes result[1], s2
    assert_includes result[1], s3
  end

  test "graph mode groups steps by BFS depth from start" do
    # Create as non-graph first, add steps, then switch to graph after transitions
    workflow = Workflow.create!(title: "Graph", user: @user, graph_mode: false)
    s1 = Steps::Action.create!(workflow: workflow, position: 0, title: "Start")
    s2 = Steps::Action.create!(workflow: workflow, position: 1, title: "Branch A")
    s3 = Steps::Action.create!(workflow: workflow, position: 2, title: "Branch B")
    s4 = Steps::Resolve.create!(workflow: workflow, position: 3, title: "End", resolution_type: "success")

    # Create transitions before enabling graph mode
    Transition.create!(step: s1, target_step: s2, position: 0)
    Transition.create!(step: s1, target_step: s3, position: 1)
    Transition.create!(step: s2, target_step: s4, position: 0)
    Transition.create!(step: s3, target_step: s4, position: 0)

    workflow.update_columns(graph_mode: true, start_step_id: s1.id)

    result = FlowDiagramService.call(workflow.reload)

    assert_equal 3, result.size
    assert_equal [s1], result[0]
    assert_includes result[1], s2
    assert_includes result[1], s3
    assert_equal [s4], result[2]
  end

  test "graph mode includes orphan steps at end" do
    workflow = Workflow.create!(title: "Orphan", user: @user, graph_mode: false)
    s1 = Steps::Action.create!(workflow: workflow, position: 0, title: "Connected")
    s2 = Steps::Action.create!(workflow: workflow, position: 1, title: "Orphan")

    workflow.update_columns(graph_mode: true, start_step_id: s1.id)

    result = FlowDiagramService.call(workflow.reload)

    assert_equal 2, result.size
    assert_equal [s1], result[0]
    assert_equal [s2], result[1]
  end
end
