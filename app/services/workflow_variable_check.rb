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

  # The only columns that can put a name in the bag. Steps of OTHER workflows in
  # the closure are read as these and nothing else — see #foreign_writers.
  NAME_COLUMNS = %i[type title variable_name options output_fields variable_mapping].freeze

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

  # Conditions are matched the way ConditionEvaluator#lookup_value reads them,
  # not the way they are spelled: it falls back to a case-insensitive key match,
  # and it resolves the legacy name "answer" as the last value given — which is
  # what condition_presets.js writes for a Question with no variable_name, so
  # warning on it would be warning on the builder's own default output.
  # Interpolation below stays exact: VariableInterpolator does no such fallback.
  def condition_findings
    named = names_by_step { |step| step.transitions.filter_map { |t| t.condition.to_s[CONDITION_VARIABLE, 1] } }
    return [] if named.empty?

    known = WorkflowVariableNames.condition_matcher(defined_variables)
    findings_for(named, code: :undefined_variable, &known)
  end

  def interpolation_findings
    named = names_by_step { |step| interpolated_text(step).scan(VariableInterpolator::VARIABLE_PATTERN).flatten }
    return [] if named.empty?

    findings_for(named, code: :undefined_interpolation) { |name| defined_variables.include?(name) }
  end

  # Names are gathered BEFORE the defined set is asked for, because most
  # workflows name no variable anywhere and the defined set is the expensive
  # half: it walks the sub-flow closure. A workflow with nothing to check costs
  # no closure queries at all.
  def names_by_step
    steps.each_with_object({}) do |step, named|
      names = yield(step).uniq
      named[step.uuid] = names if names.any?
    end
  end

  # `code` is a keyword on purpose. The classification guard in
  # workflow_health_check_publish_blockers_test finds this file's codes by
  # scanning for the keyword followed by a symbol, so a positional symbol is
  # invisible to it — and so is any example of the form written in a comment,
  # which it would read as a real code.
  def findings_for(named, code:, &)
    named.filter_map do |uuid, names|
      unknown = names.reject(&)
      Finding.new(step_uuid: uuid, code: code, variables: unknown) if unknown.any?
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
    @defined_variables ||= WorkflowVariableNames.written_by((own_writers + foreign_writers).map { |row| to_row(row) })
  end

  # `options` is a Form's field list and a Question's choice list, so it only
  # counts as names on a Form. What a row WRITES is WorkflowVariableNames' job;
  # this only says how a steps-table tuple reads.
  def to_row((type, title, variable_name, options, output_fields, mapping))
    WorkflowVariableNames::Row.new(title: title, variable_name: variable_name,
                                   form_fields: (options if type == "Steps::Form"),
                                   output_fields: output_fields, mapping: mapping)
  end

  def own_writers
    steps.map { |step| NAME_COLUMNS.map { |column| step.read_attribute(column) } }
  end

  # One shared sub-flow — "Verify identity", called by most workflows — pulls
  # nearly the whole organisation into the closure, and this runs on every
  # health fetch, which the builder makes after every autosave. So foreign steps
  # are six plucked columns in one query, never instantiated records.
  def foreign_writers
    others = contributing_workflow_ids - [workflow.id]
    return [] if others.empty?

    Step.where(workflow_id: others.to_a).pluck(*NAME_COLUMNS)
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
