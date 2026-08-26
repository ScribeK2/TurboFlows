# One-step rewind through a run.
#
# Rewinding used to mean "empty the variable bag and rebuild it by replaying the
# execution path." That could only ever recover Question answers, because
# nothing else is recorded on an entry in a replayable form — an action's
# output_fields land in results and leave only action_completed behind. So a
# single Back destroyed every action output, form response and escalation value
# in the run.
#
# Entries now carry an undo log (Scenario#append_path_entry), so a step is
# reversed by applying its own delta rather than by reconstructing everything
# that came before it.
class ScenarioNavigator
  def initialize(scenario, workflow)
    @scenario = scenario
    @workflow = workflow
  end

  # Whether this run can step backwards.
  #
  # Runs that began before entries carried an undo log cannot be rewound: the
  # values are not recoverable from their entries, and the old rebuild silently
  # destroyed them. Back is hidden for those rather than offering a control that
  # loses data. The mixed population ages out with scenario retention.
  def can_go_back?
    entries = @scenario.execution_path
    entries.present? && entries.all? { |entry| entry.key?("results_delta") }
  end

  def go_back
    return unless can_go_back?

    popped_step = pop_to_interactive_step
    return unless popped_step

    restore_position(popped_step)
    @scenario.status = "active" if @scenario.completed?
    @scenario.save!
  end

  private

  # Pop entries until an interactive one comes off, undoing each as it goes.
  #
  # Sub-flow entries are passed over — there is nothing for the user to answer
  # on one — but the child scenario they started has to be stopped, or the
  # parent is left in awaiting_subflow pointing at a child its path no longer
  # references.
  def pop_to_interactive_step
    while @scenario.execution_path.size.positive?
      candidate = @scenario.execution_path.pop
      undo(candidate)

      if candidate["step_type"] == "sub_flow"
        abandon_child(candidate)
        next
      end

      return candidate
    end
    nil
  end

  # Apply an entry's undo log: restore what each key held before that step, and
  # remove the keys the step introduced.
  def undo(entry)
    @scenario.results = apply_delta(@scenario.results, entry["results_delta"])
    @scenario.inputs  = apply_delta(@scenario.inputs, entry["inputs_delta"])
  end

  def apply_delta(bag, delta)
    bag = (bag || {}).dup
    return bag if delta.blank?

    delta.each do |key, change|
      if change["was"].nil?
        bag.delete(key)
      else
        bag[key] = change["was"]
      end
    end
    bag
  end

  # Stop the child a popped sub-flow entry started, and release the parent.
  #
  # stop_frame!, not stop!: stop! deliberately walks up to the root and stops
  # the whole tree, which here would stop the very run the user is rewinding.
  # Only the abandoned branch comes down.
  def abandon_child(entry)
    child_id = entry["child_scenario_id"]
    child = @scenario.child_scenarios.find_by(id: child_id) if child_id.present?
    if child
      child.unfinished_descendants.each(&:stop_frame!)
      child.stop_frame!
    end
    @scenario.status = "active" if @scenario.awaiting_subflow?
  end

  def restore_position(popped_step)
    if popped_step["step_uuid"].present?
      @scenario.current_node_uuid = popped_step["step_uuid"]
    elsif popped_step["step_index"].present?
      @scenario.current_step_index = popped_step["step_index"].to_i
    end
    @scenario.current_step_index = [@scenario.current_step_index.to_i - 1, 0].max
  end
end
