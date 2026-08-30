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
  test "action entry captures the script the agent actually saw" do
    scripted = Workflow.create!(title: "Scripted WF", user: @user)
    act = Steps::Action.create!(workflow: scripted, title: "Read script", position: 0)
    act.instructions = "Tell the customer about ticket {{ticket_id}}."
    act.save!
    done = Steps::Resolve.create!(workflow: scripted, title: "Done", position: 1)
    Transition.create!(step: act, target_step: done, position: 0)
    scripted.update!(start_step: act)

    scenario = Scenario.create!(
      workflow: scripted, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: act.uuid, execution_path: [],
      results: { "ticket_id" => "T-42" }, inputs: {}
    )
    scenario.process_step(nil)

    assert_equal "Tell the customer about ticket T-42.",
                 scenario.execution_path.last["body"],
                 "interpolated as the agent read it, not as the variables stand later"
  end

  test "message entry captures its body under the same key as other step types" do
    messaging = Workflow.create!(title: "Message WF", user: @user)
    msg = Steps::Message.create!(workflow: messaging, title: "Notice", position: 0)
    msg.content = "Please hold."
    msg.save!
    done = Steps::Resolve.create!(workflow: messaging, title: "Done", position: 1)
    Transition.create!(step: msg, target_step: done, position: 0)
    messaging.update!(start_step: msg)

    scenario = Scenario.create!(
      workflow: messaging, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: msg.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)

    assert_equal "Please hold.", scenario.execution_path.last["body"],
                 "one key means the thread reads bodies the same way for every step type"
  end

  test "captured body is capped" do
    scripted = Workflow.create!(title: "Long Script WF", user: @user)
    act = Steps::Action.create!(workflow: scripted, title: "Long", position: 0)
    act.instructions = "x" * (Scenario::ENTRY_TEXT_LIMIT + 500)
    act.save!
    done = Steps::Resolve.create!(workflow: scripted, title: "Done", position: 1)
    Transition.create!(step: act, target_step: done, position: 0)
    scripted.update!(start_step: act)

    scenario = Scenario.create!(
      workflow: scripted, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: act.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)

    assert_operator scenario.execution_path.last["body"].length, :<=, Scenario::ENTRY_TEXT_LIMIT
  end
  # Characterisation, not a regression guard: symbol keys are currently
  # harmless, because save! round-trips a json attribute through its serialised
  # form and every reader runs after a save. The window between appending an
  # entry and saving it is the exception, and it is where the streamed runner's
  # renderers will live — so it is pinned rather than left to be rediscovered.
  test "an entry is string-keyed before it is saved" do
    entry = @scenario.send(:build_path_entry, @action)
    @scenario.append_path_entry(entry)

    symbol_keys = @scenario.execution_path.last.keys.grep_v(String)

    assert_empty symbol_keys, "an entry read before save must not answer nil to a string key"
  end
  test "escalate entry records where it sent the call" do
    escalating = Workflow.create!(title: "Escalate Detail WF", user: @user)
    esc = Steps::Escalate.create!(
      workflow: escalating, title: "Escalate", position: 0,
      target_type: "supervisor", target_value: "Tier 2", priority: "urgent"
    )
    done = Steps::Resolve.create!(workflow: escalating, title: "Done", position: 1)
    Transition.create!(step: esc, target_step: done, position: 0)
    escalating.update!(start_step: esc)

    scenario = Scenario.create!(
      workflow: escalating, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: esc.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)

    entry = scenario.execution_path.last

    assert_equal "supervisor", entry["target_type"]
    assert_equal "urgent", entry["priority"]
  end

  # The words a person typed belong on the entry for the same reason the target
  # does: results carry one _escalation blob that a later escalate step
  # overwrites, and the reason is *consumed* off inputs as it is read. The entry
  # is the only place it survives as a fact about this step.
  test "escalate entry keeps the reason the agent typed" do
    escalating = Workflow.create!(title: "Escalate Reason WF", user: @user)
    esc = Steps::Escalate.create!(
      workflow: escalating, title: "Escalate", position: 0,
      target_type: "supervisor", reason_required: true
    )
    done = Steps::Resolve.create!(workflow: escalating, title: "Done", position: 1)
    Transition.create!(step: esc, target_step: done, position: 0)
    escalating.update!(start_step: esc)

    scenario = Scenario.create!(
      workflow: escalating, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: esc.uuid, execution_path: [], results: {},
      inputs: { "escalation_reason" => "Customer asked for a manager" }
    )
    scenario.process_step(nil)

    assert_equal "Customer asked for a manager", scenario.execution_path.last["reason"]
  end

  test "resolve entry keeps the notes the agent typed" do
    resolving = Workflow.create!(title: "Resolve Notes WF", user: @user)
    res = Steps::Resolve.create!(
      workflow: resolving, title: "Confirm identity", position: 0,
      resolution_type: "success", notes_required: true
    )
    resolving.update!(start_step: res)

    scenario = Scenario.create!(
      workflow: resolving, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: res.uuid, execution_path: [], results: {},
      inputs: { "resolution_notes" => "Checked DOB and last four" }
    )
    scenario.process_step(nil)

    assert_equal "Checked DOB and last four", scenario.execution_path.last["notes"]
  end

  test "a resolve nobody had to answer records no notes" do
    resolving = Workflow.create!(title: "Resolve Plain WF", user: @user)
    res = Steps::Resolve.create!(workflow: resolving, title: "Done", position: 0, resolution_type: "success")
    resolving.update!(start_step: res)

    scenario = Scenario.create!(
      workflow: resolving, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: res.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)

    assert_not scenario.execution_path.last.key?("notes"),
               "an absent key is what tells the thread nobody stopped here"
  end

  test "resolve entry records how the run ended" do
    resolving = Workflow.create!(title: "Resolve Detail WF", user: @user)
    res = Steps::Resolve.create!(
      workflow: resolving, title: "Fixed", position: 0, resolution_type: "transfer"
    )
    resolving.update!(start_step: res)

    scenario = Scenario.create!(
      workflow: resolving, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: res.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step(nil)

    assert_equal "transfer", scenario.execution_path.last["resolution_type"]
  end
end
