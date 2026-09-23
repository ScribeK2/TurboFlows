# Which step a workflow starts at, when something other than an import sets it.
#
# Both writes are update_column on purpose: a full save would bump the
# workflow's lock_version under whatever the title or Details autosave is
# holding, and that save would then be refused as stale.
module WorkflowStartStep
  extend ActiveSupport::Concern

  # Destroys one of this workflow's steps. When it was the start, the start
  # passes to the step it continued into, so the trunk stays the trunk (QA
  # B-005): taking the first step by position could pick a side branch and drop
  # the whole trunk into Unconnected, and nothing in the builder sets the start.
  def destroy_step(step)
    transaction do
      successors = step.id == start_step_id ? start_successor_ids(step) : []
      update_column(:start_step_id, nil) if step.id == start_step_id
      step.destroy
      assign_start_step(prefer: successors)
    end
  end

  # Sets the start when there is none: the first of `prefer` that is still a
  # step of this workflow, else the first step by position. Queried fresh, so a
  # loaded `steps` association never hands back a step just destroyed.
  def assign_start_step(prefer: [])
    return if start_step_id.present?

    candidates = steps.where(id: prefer).index_by(&:id)
    start = prefer.lazy.filter_map { |id| candidates[id] }.first
    start ||= steps.reorder(:position).first
    update_column(:start_step_id, start.id) if start
  end

  private

  # The deleted start's wired doors, last first: the last door is the outline's
  # continuation (Step::Doors, StepOutline), and when it is a stub the wired
  # door nearest it stands in. A door back to the step itself names a step that
  # is gone by the time assign_start_step looks, so it is passed over there. A
  # step with no doors (a Resolve, a handoff) has no successors, so the start
  # falls back to the first step by position. Read before the destroy, which
  # takes the step's transitions with it; loading them plainly first keeps
  # Doors from preloading every target step when only ids are read.
  def start_successor_ids(step)
    step.transitions.load
    Step::Doors.for(step).doors.reverse.filter_map { |door| door.transition&.target_step_id }
  end
end
