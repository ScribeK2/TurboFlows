# Finds branches that can never fire and step copy that shows an agent raw
# braces, both for the same reason: the variable named does not exist.
#
# The failure this catches is one move in the step panel. Rename a Question's
# `variable_name` and every condition written against the old name keeps the old
# name — nothing rewrites them, nothing refuses the save, and until now the
# health check reported zero errors. The run then falls through the graph and is
# recorded as `outcome: "stranded"`, which the previous block made visible. This
# is the half that stops it happening.
#
# `StrictImportValidator` asks the same questions on the import path and is NOT
# reused here: it takes parsed hashes, this takes AR records, and the adapter
# between them is the real cost of the shared service both should eventually
# call. Two differences are deliberate rather than incidental, and the importer
# is wrong on both:
#
#   - its `defined_variables` reads `variable_name` only, so it already warns on
#     correct files whose conditions name a step title, an Action output_field or
#     a Form field — all of which the runtime really does write;
#   - its interpolation pattern allows `{{ spaces }}`, which the runtime never
#     interpolates whatever the variable is.
class WorkflowVariableCheck
  Finding = Data.define(:step_uuid, :code, :variables)

  # The leading identifier of an expression condition. A bare value condition
  # ("yes") names no variable and is matched against the source step's own
  # answer, so there is nothing here to check.
  CONDITION_VARIABLE = /\A\s*(\w+)\s*(?:>=|<=|==|!=|>|<)/

  # Plain fields the runner actually interpolates: `runner/_question` does
  # `title` and `question`, `runner/_thread_card` does `title`. `help_text` is
  # deliberately absent — nothing interpolates it, so braces there are a
  # different defect from this one. The rich-text half comes from
  # StepFieldMap::RICH_TEXT, every member of which is rendered through
  # StepHelper#render_step_content with the run's variables.
  INTERPOLATED_PLAIN = %i[title question].freeze

  def self.call(workflow, steps)
    new(workflow, steps).call
  end

  def initialize(workflow, steps)
    @workflow = workflow
    @steps = steps
  end

  def call
    return [] if @steps.empty?

    preload_rich_text
    condition_findings + interpolation_findings
  end

  private

  attr_reader :workflow, :steps

  def condition_findings
    steps.filter_map do |step|
      names = step.transitions.filter_map { |t| t.condition.to_s[CONDITION_VARIABLE, 1] }
      unknown = names.uniq - defined_variables.to_a
      next if unknown.empty?

      Finding.new(step_uuid: step.uuid, code: :undefined_variable, variables: unknown)
    end
  end

  def interpolation_findings
    steps.filter_map do |step|
      names = interpolated_text(step).scan(VariableInterpolator::VARIABLE_PATTERN).flatten
      unknown = names.uniq - defined_variables.to_a
      next if unknown.empty?

      Finding.new(step_uuid: step.uuid, code: :undefined_interpolation, variables: unknown)
    end
  end

  # Every string the runner puts in front of an agent after interpolating it.
  def interpolated_text(step)
    plain = INTERPOLATED_PLAIN.filter_map do |field|
      value = step.public_send(field) if step.respond_to?(field)
      value if value.is_a?(String)
    end

    rich = StepFieldMap.rich_text_fields(step.step_type).filter_map do |field|
      step.public_send(field)&.body&.to_plain_text if step.respond_to?(field)
    end

    # An Action's output_fields interpolate their `value` before storing it, so
    # an unknown name there lands in the variable bag as literal braces and is
    # read by whatever uses it next.
    outputs = Array(step.try(:output_fields)).filter_map do |field|
      field["value"] if field.is_a?(Hash) && field["value"].is_a?(String)
    end

    (plain + rich + outputs).join("\n")
  end

  # Everything that can be in the run's variable bag by the time this workflow
  # is executing — its own writers, plus every workflow whose bag flows into it.
  def defined_variables
    @defined_variables ||= variables_written_by(related_workflow_steps)
  end

  # What a set of steps puts into `results`. Six writers, all in
  # ScenarioStepProcessor: a Question writes its `variable_name` AND its title,
  # every other type writes its title, an Action writes each output_field name,
  # and a Form writes each submitted field name. StepResolver's simple-value
  # match reads `results[variable_name] || results[title]`, so a title is a real
  # key and not a curiosity.
  def variables_written_by(collection)
    collection.each_with_object(Set.new) do |step, names|
      names << step.title.to_s.strip if step.title.present?
      names << step.variable_name.to_s.strip if step.try(:variable_name).present?

      Array(step.try(:output_fields)).each do |field|
        names << field["name"].to_s.strip if field.is_a?(Hash) && field["name"].present?
      end

      next unless step.is_a?(Steps::Form)

      Array(step.try(:fields)).each do |field|
        names << field["name"].to_s.strip if field.is_a?(Hash) && field["name"].present?
      end
    end
  end

  def related_workflow_steps
    others = contributing_workflow_ids - [workflow.id]
    return steps if others.empty?

    steps + Step.where(workflow_id: others).to_a
  end

  # Every workflow whose variables can reach this one, to a fixed point.
  #
  # A bag flows along sub-flow edges in BOTH directions, which is why neither
  # side can simply be skipped:
  #
  #   - a caller seeds its child with its WHOLE bag before applying
  #     variable_mapping, so a target legitimately reads variables no step in it
  #     sets. True for a handoff too, which is seeded the same way;
  #   - a RETURNING sub-flow merges every non-internal child key back into the
  #     parent, so a caller legitimately reads variables only its child sets.
  #
  # Transitive because inheritance is: in A -> B -> C, C receives what B had and
  # B had everything A had — the same reasoning StrictImportValidator records for
  # the callee direction. Skipping instead of resolving was measured against the
  # dev corpus and would have left 310 of 409 conditions unchecked.
  #
  # Position is deliberately ignored: whether the caller set the variable before
  # the sub-flow step, or the child returned it after, is not read here. That
  # makes the rule laxer, which is the trade this whole check is built on — one
  # false positive costs more than one missed dead branch.
  #
  # Iterative to a fixed point rather than recursive, so a cyclic bundle
  # terminates here instead of relying on SubflowValidator.
  def contributing_workflow_ids
    seen = Set[workflow.id]
    frontier = [workflow.id]

    while frontier.any?
      callers = Steps::SubFlow.where(sub_flow_workflow_id: frontier).pluck(:workflow_id)
      returns = Steps::SubFlow.where(workflow_id: frontier, sub_flow_returns: true)
                              .pluck(:sub_flow_workflow_id)

      frontier = (callers + returns).compact.uniq.reject { |id| seen.include?(id) }
      seen.merge(frontier)
    end

    seen
  end

  # Rich text lives on STI subclasses, so it preloads per type. Without this the
  # scan costs one query per Action/Message/Escalate/Resolve/Form step on a path
  # the health JSON hits after every autosave — see the query-count test.
  def preload_rich_text
    { rich_text_instructions: [Steps::Action, Steps::Form],
      rich_text_content: [Steps::Message],
      rich_text_notes: [Steps::Escalate],
      rich_text_description: [Steps::Resolve] }.each do |assoc, klasses|
      typed = steps.select { |step| klasses.any? { |klass| step.is_a?(klass) } }
      next if typed.empty?

      ActiveRecord::Associations::Preloader.new(records: typed, associations: [assoc]).call
    end
  end
end
