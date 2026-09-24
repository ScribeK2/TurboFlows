require "test_helper"

# Scenario.start! is how every run begins: the builder's Run Scenario, the
# Player's start, and a share link. Each used to write its own nine-attribute
# create and settle, and they had drifted - Scenario mode never named its
# purpose and leaned on the column default.
class ScenarioStartTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "scenario-start-#{SecureRandom.hex(4)}@example.com", password: "password123456")
  end

  def question_workflow
    workflow = Workflow.create!(title: "Start WF", user: @user)
    q = Steps::Question.create!(workflow: workflow, title: "Q", position: 0, variable_name: "qv")
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 1)
    Transition.create!(step: q, target_step: done, position: 0)
    workflow.update!(start_step: q)
    [workflow, q]
  end

  test "a run starts at the workflow's first step with an empty history" do
    workflow, q = question_workflow

    run = Scenario.start!(workflow, user: @user, purpose: "live")

    assert_predicate run, :persisted?
    assert_equal [workflow, @user, "live", false], [run.workflow, run.user, run.purpose, run.shared_access]
    assert_equal q.uuid, run.current_node_uuid
    assert_equal [[], {}, {}], [run.execution_path, run.results, run.inputs]
    assert_predicate run, :active?
    assert_not_nil run.started_at
  end

  test "a simulation says so rather than leaning on the column default" do
    workflow, = question_workflow

    assert_equal "simulation", Scenario.start!(workflow, user: @user, purpose: "simulation").purpose
  end

  test "a share-link run can belong to nobody, and is marked shared" do
    workflow, = question_workflow

    run = Scenario.start!(workflow, user: nil, purpose: "live", shared_access: true)

    assert_nil run.user
    assert_predicate run, :shared_access?
  end

  # Nothing POSTs between creating a run and its first GET, so starting has to
  # settle it: a first step that is a sub-flow has no card to show.
  test "a run whose first step is a sub-flow starts inside the sub-flow" do
    child = Workflow.create!(title: "Child WF", user: @user)
    cq = Steps::Question.create!(workflow: child, title: "CQ", position: 0, variable_name: "cv")
    Transition.create!(step: cq, target_step: Steps::Resolve.create!(workflow: child, title: "CDone", position: 1))
    child.update!(start_step: cq)

    parent = Workflow.create!(title: "Parent WF", user: @user)
    sf = Steps::SubFlow.create!(workflow: parent, title: "SF", position: 0, sub_flow_workflow_id: child.id)
    Transition.create!(step: sf, target_step: Steps::Resolve.create!(workflow: parent, title: "Done", position: 1))
    parent.update!(start_step: sf)

    landed = Scenario.start!(parent, user: @user, purpose: "live")

    assert_equal cq.uuid, landed.current_node_uuid
    assert_equal parent, landed.run_origin.workflow
  end
end
