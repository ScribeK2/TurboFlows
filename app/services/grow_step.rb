# Adds a step to a workflow the way an author means it: after the step they
# were on, with the connection from that step already made.
#
# The builder used to append a step with no connection and leave the author to
# open a panel, find the new step in a <select> and bind the two - then learn
# from the health check which ones they had forgotten. StepBuilder is not this:
# it bulk-writes an import or a template and demands a Resolve in the payload.
class GrowStep
  class Refused < StandardError; end

  def self.create(workflow:, step_type:, from_step: nil, attrs: {}, label: nil, condition: nil)
    new(workflow).create(step_type:, from_step:, attrs:, label:, condition:)
  end

  def self.connect(workflow:, from_step:, target_step:, label: nil, condition: nil)
    new(workflow).connect(from_step:, target_step:, label:, condition:)
  end

  def initialize(workflow)
    @workflow = workflow
  end

  def create(step_type:, from_step:, attrs:, label:, condition:)
    check_source!(from_step) if from_step

    Step.transaction do
      check_door_is_free!(from_step, condition) if from_step

      step = Step.class_for_type(step_type).new(attrs.to_h.merge(workflow: @workflow, position: claim_position(from_step)))
      step.title = "Untitled #{step_type.to_s.titleize}" if step.title.blank?
      prepare_question(step) if step.is_a?(Steps::Question)
      step.save!

      connect_steps(from_step, step, label:, condition:) if from_step
      assign_start_step(step)
      step
    end
  end

  # One door, one target: a door already wired is pointed somewhere else rather
  # than given a second connection that could never fire (first match wins).
  def connect(from_step:, target_step:, label:, condition:)
    check_source!(from_step)

    Step.transaction do
      existing = Step::Doors.for(from_step).door_for(condition)&.transition
      if existing
        existing.update!(target_step: target_step)
        existing
      else
        connect_steps(from_step, target_step, label:, condition:)
      end
    end
  end

  private

  def check_source!(from_step)
    raise Refused, "That step belongs to another workflow." if from_step.workflow_id != @workflow.id
    raise Refused, "A Resolve step ends the workflow, so nothing can follow it." if from_step.is_a?(Steps::Resolve)
    raise Refused, "This step hands the run to another workflow, so nothing can follow it." if from_step.hands_off?
  end

  # A door takes one step. The buttons that grow only ever sit on a stub, but a
  # stub's data-grow-* attributes go stale the moment someone else wires that
  # door - or a second click races the first - and a second edge on it could
  # never fire (first match wins), so the step it reached would be one nothing
  # points at. #connect retargets instead, because there the author has just
  # chosen where the door should go; here they were told it went nowhere.
  def check_door_is_free!(from_step, condition)
    door = Step::Doors.for(from_step).door_for(condition)
    return if door.nil? || door.stub?

    target = door.target_step.title.presence || "another step"
    raise Refused, "“#{door.label}” already leads to “#{target}”. Change it from the step's panel instead."
  end

  # Directly after the parent, using whatever numbering the workflow already
  # has (0-based from a service, 1-based from the builder) - the same shift
  # HealthFixesController#add_resolve_after makes.
  def claim_position(from_step)
    return @workflow.steps.maximum(:position).to_i + 1 unless from_step

    position = from_step.position + 1
    @workflow.steps.where(position: position..).update_all("position = position + 1")
    position
  end

  # Every builder-made Question is titled "Untitled Question", so the model's
  # own callback would name them all `untitled_question`, and it never renames.
  #
  # Yes/No is what a call-centre Question usually is, and a wrong guess shows at
  # once as two doors. The builder used to select nothing, because a silent
  # default to Text Input ran and was wrong with nothing on screen to say so.
  def prepare_question(step)
    step.answer_type = "yes_no" if step.answer_type.blank?
    return if step.variable_name.present?

    base = Steps::Question.variable_name_from(step.title)
    taken = @workflow.steps.where(type: "Steps::Question").pluck(:variable_name).to_set
    name = base
    suffix = 1
    name = "#{base}_#{suffix += 1}" while taken.include?(name)
    step.variable_name = name
  end

  def connect_steps(from_step, target, label:, condition:)
    transition = Transition.create!(step: from_step, target_step: target,
                                    label: label.presence, condition: condition.presence,
                                    position: from_step.transitions.count)
    Transition.settle_positions(from_step)
    transition
  end

  # Same write StepsController#ensure_start_step_assigned makes, for the same
  # reason: a full save would bump the workflow's lock_version under whatever
  # the title or Details autosave is holding, and refuse that save as stale.
  def assign_start_step(step)
    return if @workflow.start_step_id.present?

    first = @workflow.steps.order(:position).first || step
    @workflow.update_column(:start_step_id, first.id)
  end
end
