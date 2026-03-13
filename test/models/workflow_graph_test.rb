require "test_helper"

class WorkflowGraphTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:one)
  end

  test "graph_mode? returns correct value" do
    linear_workflow = Workflow.create!(title: "Linear", user: @user, graph_mode: false)
    graph_workflow = Workflow.create!(title: "Graph", user: @user, graph_mode: true)

    assert_not linear_workflow.graph_mode?
    assert_predicate graph_workflow, :graph_mode?
    assert_predicate linear_workflow, :linear_mode?
    assert_not graph_workflow.linear_mode?
  end

  test "graph_steps returns hash keyed by UUID" do
    workflow = Workflow.create!(title: "Graph Steps Test", user: @user, graph_mode: true)
    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "uuid-1", title: "Step 1")
    step2 = Steps::Action.create!(workflow: workflow, position: 1, uuid: "uuid-2", title: "Step 2")
    Transition.create!(step: step1, target_step: step2, position: 0)

    graph_steps = workflow.graph_steps

    assert_instance_of Hash, graph_steps
    assert_equal 2, graph_steps.length
    assert graph_steps.key?("uuid-1")
    assert graph_steps.key?("uuid-2")
    assert_equal "Step 1", graph_steps["uuid-1"].title
  end

  test "start_node returns start_step when set" do
    workflow = Workflow.create!(title: "Start Node Test", user: @user, graph_mode: true)
    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "uuid-1", title: "Not Start")
    step2 = Steps::Question.create!(workflow: workflow, position: 1, uuid: "uuid-2", title: "Start Step", question: "Begin?")
    Transition.create!(step: step2, target_step: step1, position: 0)
    workflow.update!(start_step: step2)

    start = workflow.start_node

    assert_not_nil start
    assert_equal "uuid-2", start.uuid
    assert_equal "Start Step", start.title
  end

  test "start_node defaults to first step if not set" do
    workflow = Workflow.create!(title: "Default Start Test", user: @user, graph_mode: true)
    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "uuid-1", title: "First Step")
    step2 = Steps::Action.create!(workflow: workflow, position: 1, uuid: "uuid-2", title: "Second Step")
    Transition.create!(step: step1, target_step: step2, position: 0)

    start = workflow.start_node

    assert_not_nil start
    assert_equal "uuid-1", start.uuid
  end

  test "terminal_nodes returns steps without transitions in graph mode" do
    workflow = Workflow.create!(title: "Terminal Test", user: @user, graph_mode: true)
    step_a = Steps::Question.create!(workflow: workflow, position: 0, uuid: "a", title: "Start", question: "Which path?")
    step_b = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "End 1")
    step_c = Steps::Action.create!(workflow: workflow, position: 2, uuid: "c", title: "End 2")
    Transition.create!(step: step_a, target_step: step_b, position: 0)
    Transition.create!(step: step_a, target_step: step_c, position: 1)
    workflow.update!(start_step: step_a)

    terminals = workflow.terminal_nodes

    assert_equal 2, terminals.length
    terminal_titles = terminals.map(&:title).sort
    assert_equal ["End 1", "End 2"], terminal_titles
  end

  test "subflow_steps returns sub_flow type steps" do
    target = Workflow.create!(title: "Target", user: @user, status: "published")

    workflow = Workflow.create!(title: "Subflow Test", user: @user, graph_mode: true)
    step_a = Steps::Action.create!(workflow: workflow, position: 0, uuid: "a", title: "Action")
    step_b = Steps::SubFlow.create!(workflow: workflow, position: 1, uuid: "b", title: "Call Sub", sub_flow_workflow_id: target.id)
    step_c = Steps::SubFlow.create!(workflow: workflow, position: 2, uuid: "c", title: "Call Sub 2", sub_flow_workflow_id: target.id)
    Transition.create!(step: step_a, target_step: step_b, position: 0)
    Transition.create!(step: step_b, target_step: step_c, position: 0)
    workflow.update!(start_step: step_a)

    subflows = workflow.subflow_steps

    assert_equal 2, subflows.length
    assert(subflows.all? { |s| s.is_a?(Steps::SubFlow) })
  end

  test "referenced_workflow_ids returns unique workflow IDs" do
    target1 = Workflow.create!(title: "Target 1", user: @user, status: "published")
    target2 = Workflow.create!(title: "Target 2", user: @user, status: "published")

    workflow = Workflow.create!(title: "References Test", user: @user, graph_mode: true)
    step_a = Steps::SubFlow.create!(workflow: workflow, position: 0, uuid: "a", title: "Sub 1", sub_flow_workflow_id: target1.id)
    step_b = Steps::SubFlow.create!(workflow: workflow, position: 1, uuid: "b", title: "Sub 2", sub_flow_workflow_id: target2.id)
    step_c = Steps::SubFlow.create!(workflow: workflow, position: 2, uuid: "c", title: "Sub 3", sub_flow_workflow_id: target1.id)
    Transition.create!(step: step_a, target_step: step_b, position: 0)
    Transition.create!(step: step_b, target_step: step_c, position: 0)
    workflow.update!(start_step: step_a)

    ids = workflow.referenced_workflow_ids

    assert_equal 2, ids.length
    assert_includes ids, target1.id
    assert_includes ids, target2.id
  end

  test "validates graph structure in graph mode with AR steps" do
    workflow = Workflow.create!(title: "Invalid Graph", user: @user, graph_mode: true, status: "published")
    step_a = Steps::Action.create!(workflow: workflow, position: 0, uuid: "a", title: "A")
    step_b = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "B")
    workflow.update_column(:start_step_id, step_a.id)

    workflow.reload
    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("dead end") || e.include?("unreachable") || e.include?("reachable") },
      "Expected graph validation error, got: #{workflow.errors[:steps].inspect}")
  end

  test "validates subflow references with AR steps" do
    workflow = Workflow.create!(title: "Invalid Subflow", user: @user)
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

  test "step_type_counts returns correct counts" do
    workflow = Workflow.create!(title: "Counts Test", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, uuid: "q1", title: "Q1", question: "?")
    Steps::Question.create!(workflow: workflow, position: 1, uuid: "q2", title: "Q2", question: "?")
    Steps::Action.create!(workflow: workflow, position: 2, uuid: "a1", title: "A1")

    counts = workflow.step_type_counts

    assert_equal 2, counts["question"]
    assert_equal 1, counts["action"]
  end

  test "find_step_by_uuid returns correct step" do
    workflow = Workflow.create!(title: "Find Test", user: @user)
    step = Steps::Action.create!(workflow: workflow, position: 0, uuid: "test-uuid", title: "Test")

    found = workflow.find_step_by_uuid("test-uuid")
    assert_equal step, found

    assert_nil workflow.find_step_by_uuid("nonexistent")
    assert_nil workflow.find_step_by_uuid(nil)
  end

  test "find_step_by_title returns correct step" do
    workflow = Workflow.create!(title: "Find Title Test", user: @user)
    step = Steps::Action.create!(workflow: workflow, position: 0, uuid: "t1", title: "My Step")

    assert_equal step, workflow.find_step_by_title("My Step")
    assert_equal step, workflow.find_step_by_title("my step") # case-insensitive
    assert_nil workflow.find_step_by_title("Nonexistent")
  end

  test "variables_with_metadata returns question variables" do
    workflow = Workflow.create!(title: "Variables Test", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, uuid: "q1", title: "Name", question: "What?", variable_name: "name", answer_type: "text")
    Steps::Action.create!(workflow: workflow, position: 1, uuid: "a1", title: "Do Thing")

    vars = workflow.variables_with_metadata

    assert_equal 1, vars.length
    assert_equal "name", vars[0][:name]
    assert_equal "text", vars[0][:answer_type]
  end

  test "serialize_steps_for_template captures all step data" do
    workflow = Workflow.create!(title: "Template Test", user: @user, graph_mode: true)
    q = Steps::Question.create!(workflow: workflow, position: 0, uuid: "q1", title: "Ask", question: "What?", variable_name: "answer", answer_type: "text")
    a = Steps::Action.create!(workflow: workflow, position: 1, uuid: "a1", title: "Do")
    Transition.create!(step: q, target_step: a, position: 0, condition: "answer == 'yes'")

    data = workflow.serialize_steps_for_template

    assert_equal 2, data.length
    assert_equal "question", data[0]["type"]
    assert_equal "Ask", data[0]["title"]
    assert_equal "What?", data[0]["question"]
    assert_equal "answer", data[0]["variable_name"]
    assert_equal 1, data[0]["transitions"].length
    assert_equal "a1", data[0]["transitions"][0]["target_uuid"]
    assert_equal "answer == 'yes'", data[0]["transitions"][0]["condition"]
  end
end
