require "test_helper"

class StepResolverTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:one)
  end

  test "resolves next step via transitions" do
    workflow = Workflow.create!(title: "Sequential Test", user: @user, graph_mode: true)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, uuid: "a", title: "Q1", question: "Test?")
    a_step = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "A1", instructions: "Do something")
    a2_step = Steps::Action.create!(workflow: workflow, position: 2, uuid: "c", title: "A2", instructions: "Done")

    Transition.create!(step: q_step, target_step: a_step, position: 0)
    Transition.create!(step: a_step, target_step: a2_step, position: 0)

    workflow.update_column(:start_step_id, q_step.id)

    resolver = StepResolver.new(workflow)
    next_step = resolver.resolve_next(q_step, {})

    assert_equal a_step, next_step
  end

  test "resolves conditional transition in graph mode" do
    workflow = Workflow.create!(title: "Conditional Graph Test", user: @user, graph_mode: true)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, uuid: "a", title: "Q1", question: "Yes or no?", variable_name: "answer")
    yes_step = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "Yes Path")
    no_step = Steps::Action.create!(workflow: workflow, position: 2, uuid: "c", title: "No Path")
    default_step = Steps::Action.create!(workflow: workflow, position: 3, uuid: "d", title: "Default Path")

    Transition.create!(step: q_step, target_step: yes_step, condition: "answer == 'yes'", position: 0)
    Transition.create!(step: q_step, target_step: no_step, condition: "answer == 'no'", position: 1)
    Transition.create!(step: q_step, target_step: default_step, position: 2)

    resolver = StepResolver.new(workflow)

    # Test yes path
    assert_equal yes_step, resolver.resolve_next(q_step, { "answer" => "yes" })
    # Test no path
    assert_equal no_step, resolver.resolve_next(q_step, { "answer" => "no" })
    # Test default path
    assert_equal default_step, resolver.resolve_next(q_step, { "answer" => "maybe" })
  end

  test "identifies terminal nodes" do
    workflow = Workflow.create!(title: "Terminal Test", user: @user, graph_mode: true)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, uuid: "a", title: "Q1", question: "Test?")
    end_step = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "End")

    Transition.create!(step: q_step, target_step: end_step, position: 0)

    resolver = StepResolver.new(workflow)

    assert_not resolver.terminal?(q_step)
    assert resolver.terminal?(end_step)
  end

  test "returns subflow marker for sub_flow steps" do
    target_workflow = Workflow.create!(title: "Target Workflow", user: @user, status: "published")

    workflow = Workflow.create!(title: "Parent Workflow", user: @user, graph_mode: true)
    sf_step = Steps::SubFlow.create!(workflow: workflow, position: 0, uuid: "a", title: "Call Sub", sub_flow_workflow_id: target_workflow.id)
    after_step = Steps::Action.create!(workflow: workflow, position: 1, uuid: "b", title: "After Sub")

    Transition.create!(step: sf_step, target_step: after_step, position: 0)
    workflow.update_column(:start_step_id, sf_step.id)

    resolver = StepResolver.new(workflow)
    result = resolver.resolve_next(sf_step, {})

    assert_instance_of StepResolver::SubflowMarker, result
    assert_equal target_workflow.id, result.target_workflow_id
    assert_equal "a", result.step_uuid
  end

  test "finds start step" do
    workflow = Workflow.create!(title: "Start Step Test", user: @user, graph_mode: true)

    a_step = Steps::Action.create!(workflow: workflow, position: 0, uuid: "a", title: "Not Start")
    q_step = Steps::Question.create!(workflow: workflow, position: 1, uuid: "b", title: "Start", question: "Begin?")

    Transition.create!(step: q_step, target_step: a_step, position: 0)
    workflow.update_column(:start_step_id, q_step.id)

    resolver = StepResolver.new(workflow.reload)
    start = resolver.start_step

    assert_equal q_step, start
    assert_equal "Start", start.title
  end

  test "resolves conditional transition with Step objects" do
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

  test "detects terminal steps" do
    workflow = Workflow.create!(title: "AR Terminal", user: @user, graph_mode: true)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, title: "Q1", question: "Test?")
    r_step = Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done")
    Transition.create!(step: q_step, target_step: r_step, position: 0)

    resolver = StepResolver.new(workflow)
    assert_not resolver.terminal?(q_step)
    assert resolver.terminal?(r_step)
  end

  test "returns SubflowMarker for sub_flow step" do
    target_wf = Workflow.create!(title: "Child", user: @user, status: "published")
    workflow = Workflow.create!(title: "Parent", user: @user, graph_mode: true)
    sf_step = Steps::SubFlow.create!(workflow: workflow, position: 0, title: "SF1", sub_flow_workflow_id: target_wf.id)

    resolver = StepResolver.new(workflow)
    result = resolver.resolve_next(sf_step, {})

    assert_instance_of StepResolver::SubflowMarker, result
    assert_equal target_wf.id, result.target_workflow_id
    assert_equal sf_step.uuid, result.step_uuid
  end

  test "finds start step from ActiveRecord" do
    workflow = Workflow.create!(title: "AR Start", user: @user, graph_mode: true)
    q_step = Steps::Question.create!(workflow: workflow, position: 0, title: "Start", question: "Begin?")
    workflow.update_column(:start_step_id, q_step.id)

    resolver = StepResolver.new(workflow.reload)
    assert_equal q_step, resolver.start_step
  end
end
