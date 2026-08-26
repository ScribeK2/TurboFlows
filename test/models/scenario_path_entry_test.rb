require "test_helper"

# The execution_path entry write format.
#
# Entries are the historical record of a run. Back restores from them, so they
# must carry enough to undo a step: results written by anything other than a
# Question cannot be reconstructed from the rest of the entry.
#
# They carry a *delta* — the keys this step changed, with their prior values —
# rather than a full snapshot of the variable bag. A snapshot is O(n) per entry
# and therefore O(n^2) per run: measured at 161KB of json for a 100-step run,
# which tripped ScenarioExecutionBenchmarkTest. The delta is O(1) per entry and
# reconstructs any point in the run by replaying forward.
class ScenarioPathEntryTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "path-entry@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Path Entry WF", user: @user)
    @action = Steps::Action.create!(
      workflow: @workflow, title: "Look up account", position: 0,
      output_fields: [{ "name" => "ticket_id", "value" => "T-42" }]
    )
    @question = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 1, variable_name: "q1_var")
    @resolve = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    Transition.create!(step: @action, target_step: @question, position: 0)
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @action)

    @scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation",
      started_at: Time.current,
      current_node_uuid: @action.uuid,
      execution_path: [], results: {}, inputs: {}
    )
  end

  test "entry records the keys the step added, with no prior value" do
    @scenario.process_step(nil)

    delta = @scenario.execution_path.last["results_delta"]

    assert delta.key?("ticket_id"), "an action's output_fields must be undoable"
    assert_nil delta["ticket_id"]["was"], "the key did not exist before this step"
  end

  test "entry records the prior value of a key the step overwrote" do
    @scenario.process_step(nil)
    @scenario.results["ticket_id"] = "T-42"
    overwrite = Steps::Action.create!(
      workflow: @workflow, title: "Reassign", position: 3,
      output_fields: [{ "name" => "ticket_id", "value" => "T-99" }]
    )
    @scenario.current_node_uuid = overwrite.uuid
    @scenario.process_step(nil)

    delta = @scenario.execution_path.last["results_delta"]

    assert_equal "T-42", delta["ticket_id"]["was"],
                 "overwrites are only undoable if the prior value is recorded"
  end

  test "entry records only what its own step changed" do
    @scenario.process_step(nil)   # writes ticket_id
    @scenario.process_step("Yes") # writes q1_var

    delta = @scenario.execution_path.last["results_delta"]

    assert_not delta.key?("ticket_id"),
               "a delta carries this step's changes, not the accumulated bag"
  end

  test "delta excludes internal underscore keys" do
    escalating = Workflow.create!(title: "Escalating WF", user: @user)
    esc = Steps::Escalate.create!(workflow: escalating, title: "Escalate", position: 0, target_type: "supervisor")
    done = Steps::Resolve.create!(workflow: escalating, title: "Done", position: 1)
    Transition.create!(step: esc, target_step: done, position: 0)
    escalating.update!(start_step: esc)

    scenario = Scenario.create!(
      workflow: escalating, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: esc.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)

    delta = scenario.execution_path.last["results_delta"]

    assert scenario.results.key?("_escalation"), "precondition: escalation metadata was written"
    assert_not delta.key?("_escalation"),
               "internal keys are rewritten wholesale by their owning step"
  end

  test "entry size does not grow with the length of the run" do
    workflow = Workflow.create!(title: "Long WF", user: @user)
    steps = (0...40).map { |i| Steps::Action.create!(workflow: workflow, title: "S#{i}", position: i) }
    tail = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 40)
    steps.each_with_index { |s, i| Transition.create!(step: s, target_step: steps[i + 1] || tail, position: 0) }
    workflow.update!(start_step: steps.first)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: steps.first.uuid, execution_path: [], results: {}, inputs: {}
    )
    80.times do
      break if scenario.complete? || scenario.stopped?
      break unless scenario.current_step

      scenario.process_step(nil)
    end

    first_delta = scenario.execution_path.first["results_delta"]
    last_delta  = scenario.execution_path[30]["results_delta"]

    assert_operator scenario.execution_path.size, :>, 30, "precondition: the run is long enough to matter"
    assert_equal first_delta.size, last_delta.size,
                 "a full snapshot made this O(n^2); the 30th entry must be no heavier than the first"
  end
end
