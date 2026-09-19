# Which names exist in a run's variable bag, and whether a condition can find
# one. The single statement of both, shared by the builder's health check
# (WorkflowVariableCheck, over AR records) and the strict importer
# (StrictImportValidator, over parsed hashes).
#
# It exists because the rule lived in two places that disagreed. The importer
# read `variable_name` alone and so warned on working files; the builder's check
# then had to discover the rest of the list one false positive at a time. Both
# now build `Row`s from their own shape and ask here. That is the whole adapter:
# the two callers differ in how they READ a step, never in what a step writes.
module WorkflowVariableNames
  # The name-bearing facts of one step. `form_fields` is the Form's field list
  # and nil for every other type — `options` means something else on a Question.
  Row = Data.define(:title, :variable_name, :form_fields, :output_fields, :mapping)

  # ConditionEvaluator#lookup_value resolves this as the last value given. It is
  # what condition_preset_controller.js#buildPresets writes for a Question with
  # no variable_name, so
  # reporting it would be reporting the builder's own default output.
  LEGACY_ANSWER = "answer".freeze

  module_function

  # Every writer is in ScenarioStepProcessor: a Question writes its
  # `variable_name` AND its title, every other type writes its title, an Action
  # writes each output_field name, a Form writes each submitted field name, and
  # a Sub-Flow's variable_mapping RENAMES — {"account_tier" => "tier"} seeds the
  # child with `tier`, and the reverse mapping writes `account_tier` back on
  # return — so both sides of every mapping are names that exist at run time.
  # StepResolver's simple-value match reads `results[variable_name] ||
  # results[title]`, so a title is a real key and not a curiosity.
  def written_by(rows)
    rows.each_with_object(Set.new) do |row, names|
      names << row.title.to_s.strip if row.title.present?
      names << row.variable_name.to_s.strip if row.variable_name.present?
      names.merge(entry_names(row.output_fields))
      names.merge(entry_names(row.form_fields))

      mapping = parse_mapping(row.mapping)
      names.merge(mapping.keys.map(&:to_s) + mapping.values.map(&:to_s))
    end
  end

  # A predicate over condition names, matched the way the evaluator reads them:
  # case-insensitively, with the legacy name always known. Interpolation must
  # NOT use this — VariableInterpolator does an exact key lookup, so
  # {{Reason}} against `reason` really does show an agent braces.
  def condition_matcher(defined)
    known = defined.to_set { |name| name.to_s.downcase } << LEGACY_ANSWER
    ->(name) { known.include?(name.to_s.downcase) }
  end

  def entry_names(entries)
    Array(entries).filter_map do |entry|
      next unless entry.is_a?(Hash)

      name = entry["name"] || entry[:name]
      name.to_s.strip if name.present?
    end
  end

  # ScenarioStepProcessor tolerates a JSON string here, so this does too.
  def parse_mapping(mapping)
    mapping = JSON.parse(mapping) if mapping.is_a?(String)
    mapping.is_a?(Hash) ? mapping : {}
  rescue JSON::ParserError
    {}
  end
end
