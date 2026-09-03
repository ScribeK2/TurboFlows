# Validates a strict-dialect import file without writing anything.
#
# Every check appends to one errors array, so a failing file comes back with all
# of its problems at once — an agent can fix ten errors in one pass but cannot
# see a silent drop. The codes are a published contract: once one ships, it does
# not get renamed.
#
# Resolution is deliberately separate from application: an unknown group or an
# unresolvable sub-flow target is a validation result, not an exception thrown
# partway through a write.
class StrictImportValidator
  Report = Data.define(:errors, :warnings, :workflow_data, :placement) do
    def valid? = errors.empty?
  end

  # The only condition forms ConditionEvaluator accepts. Quoted back to the agent
  # in the error, because there is nowhere else it could learn them.
  CONDITION_FORMS = [
    "var == 'value'", "var != 'value'", "var > 10", "var >= 10", "var < 10", "var <= 10"
  ].freeze

  # ConditionEvaluator::VALID_PATTERNS anchor at the start but not at the end, so
  # #valid? returns true for anything that merely BEGINS with a comparison —
  # "tier == 'gold' && region == 'EU'" and even "tier == 'gold' OR nonsense ((("
  # all pass it. #evaluate then reads only as much as it understands, so the rest
  # of the expression silently does nothing.
  #
  # Derive end-anchored versions from the same constant rather than restating the
  # six forms, so the two cannot drift apart. The whole string must be one
  # comparison and nothing else.
  STRICT_CONDITION_PATTERNS = ConditionEvaluator::VALID_PATTERNS.map do |pattern|
    Regexp.new("#{pattern.source}\\s*\\z")
  end.freeze

  INTERPOLATION = /\{\{\s*([a-zA-Z_]\w*)\s*\}\}/
  CONDITION_VARIABLE = /\A\s*(\w+)\s*(?:>=|<=|==|!=|>|<)/
  CONDITION_STRING_VALUE = /(?:==|!=)\s*['"]([^'"]*)['"]/

  # id, type and transitions have their own codes, so they are reported by their
  # own checks rather than as a generic missing field.
  SELF_REPORTING_FIELDS = %w[id type transitions].freeze

  def self.strict?(content)
    parsed = JSON.parse(content.to_s)
    parsed.is_a?(Hash) && parsed.key?("schema_version")
  rescue JSON::ParserError
    false
  end

  def initialize(user:, content:)
    @user = user
    @content = content
    @errors = []
    @warnings = []
  end

  def validate
    document = parse_document
    return report if document.nil?

    check_schema_version(document)
    return report if @errors.any?

    workflow = extract_single_workflow(document)
    return report if workflow.nil?

    # Placement is checked before the structural gate because it does not depend
    # on the steps at all. A file with a bad step AND a bad group would otherwise
    # cost two round trips to learn about the group — and telling an agent
    # everything at once is the point of this path.
    placement = validate_placement(workflow)

    # The passes below DO depend on sound structure: the graph validator cannot
    # traverse dangling targets, and the semantic checks read fields that a
    # malformed step may not have. So structure gates them.
    validate_structure(workflow)
    return report(placement:) if @errors.any?

    normalized = normalize(workflow)
    validate_graph(normalized)
    validate_semantics(normalized)
    resolve_sub_flow_targets(normalized)

    report(workflow_data: normalized, placement:)
  end

  private

  def parse_document
    document = JSON.parse(@content.to_s)

    unless document.is_a?(Hash)
      add_error("", "envelope_invalid", document.class.name,
                "The file must contain a JSON object at the top level.")
      return nil
    end

    document
  rescue JSON::ParserError => e
    add_error("", "malformed_json", nil, "The file is not valid JSON: #{e.message}")
    nil
  end

  def check_schema_version(document)
    version = document["schema_version"]
    return if version == ImportSchemaGenerator::SCHEMA_VERSION

    add_error("schema_version", "unsupported_schema_version", version,
              "schema_version #{version.inspect} is not supported.",
              expected: [ImportSchemaGenerator::SCHEMA_VERSION])
  end

  def extract_single_workflow(document)
    workflows = document["workflows"]

    unless workflows.is_a?(Array)
      return add_error("workflows", "envelope_invalid", workflows,
                       "The file must carry a 'workflows' array.")
    end

    if workflows.length != 1
      return add_error("workflows", "envelope_invalid", workflows.length,
                       "schema_version #{ImportSchemaGenerator::SCHEMA_VERSION} accepts " \
                       "exactly one workflow per file; this file has #{workflows.length}.")
    end

    workflow = workflows.first
    return workflow if workflow.is_a?(Hash)

    add_error("workflows[0]", "envelope_invalid", workflow.class.name,
              "Each entry in 'workflows' must be an object.")
  end

  # --- external references -----------------------------------------------------

  def validate_placement(workflow)
    placement = WorkflowPlacement.new(
      user: @user,
      groups: workflow["groups"] || [],
      folder: workflow["folder"],
      tags: workflow["tags"] || []
    )

    placement.resolve.errors.each do |error|
      add_error("workflows[0].#{error[:path]}", error[:code], error[:value], error[:message])
    end

    placement
  end

  # The lenient path does this in BaseParser#resolve_subflow_titles. The strict
  # path never runs a parser, so without this a sub_flow step would import
  # pointing at nothing — silently, which is the whole class of failure this
  # dialect exists to remove. Same lookup as the lenient resolver (published
  # workflows, case-insensitive) so both paths resolve a title identically; the
  # difference is severity, since the lenient one only marks the step incomplete.
  #
  # A draft match gets its own code. Imports land as drafts, so "import A, then
  # import B whose sub_flow targets A" fails where it used to work, and telling
  # the user A does not exist would send them off to re-author a workflow they
  # already have.
  def resolve_sub_flow_targets(workflow)
    Array(workflow["steps"]).each_with_index do |step, index|
      next unless step["type"] == "sub_flow"

      title = step["target_workflow_title"].to_s.strip
      path = "workflows[0].steps[#{index}].target_workflow_title"
      published = visible_published_workflows(title)

      if published.one?
        step["target_workflow_id"] = published.first.id
        step.delete("target_workflow_title")
      elsif published.many?
        add_error(path, "ambiguous_sub_flow_target", title,
                  "#{published.count} published workflows are titled #{title.inspect} " \
                  "(#{published.map { |w| "##{w.id}" }.join(', ')}). Rename one, or import " \
                  "this workflow without the sub-flow step and set the target in the builder.")
      else
        report_missing_sub_flow_target(title, path)
      end
    end
  end

  # Scoped to what this user may actually see, not every workflow in the install.
  # An unscoped lookup would let an importing editor bind a sub-flow to a workflow
  # they have no access to, and would confirm the existence and id of workflows
  # they cannot otherwise reach. Workflow.visible_to is already published-only.
  def visible_published_workflows(title)
    Workflow.visible_to(@user).where("LOWER(title) = LOWER(?)", title)
  end

  def report_missing_sub_flow_target(title, path)
    # Only the user's OWN drafts. The helpful case is "I imported A a moment ago
    # and it is still a draft"; anyone else's draft is none of their business, and
    # saying it exists would leak a private title back to whoever wrote the file.
    if @user.workflows.where.not(status: "published").exists?(["LOWER(title) = LOWER(?)", title])
      add_error(path, "sub_flow_target_not_published", title,
                "A workflow titled #{title.inspect} exists but is still a draft. Publish it " \
                "first — a sub-flow can only run a published workflow.")
    else
      add_error(path, "unknown_sub_flow_target", title,
                "No published workflow is titled #{title.inspect}. A sub-flow target must " \
                "already exist and be published.")
    end
  end

  # --- semantics ---------------------------------------------------------------

  # The checks that catch what a competent agent still gets wrong. ConditionEvaluator
  # accepts six regexes and nothing else — no && or ||, string values quoted,
  # numeric comparisons matching \d+ so "> 3.5" and "> -1" do not parse — and
  # #evaluate returns false for anything unparseable rather than raising. An
  # invalid condition is therefore a branch that silently never fires on a live
  # call, which is why it is an error rather than a warning.
  #
  # The variable and option checks are warnings: a variable can legitimately
  # arrive from scenario inputs rather than an upstream question, so treating
  # either as an error would reject valid files.
  def validate_semantics(workflow)
    steps = workflow["steps"]
    defined = defined_variables(steps)
    options = options_by_variable(steps)

    steps.each_with_index do |step, index|
      path = "workflows[0].steps[#{index}]"
      validate_interpolations(step, path, defined)

      Array(step["transitions"]).each_with_index do |transition, t_index|
        condition = transition["condition"]
        next if condition.blank?

        validate_condition(condition, "#{path}.transitions[#{t_index}].condition",
                           defined, options)
      end
    end
  end

  def validate_condition(condition, path, defined, options)
    unless supported_condition?(condition)
      return add_error(path, "invalid_condition_syntax", condition,
                       "#{condition.inspect} is not a supported condition. One comparison " \
                       "only — no && or ||, string values quoted, numbers whole and positive.",
                       expected: CONDITION_FORMS)
    end

    name = condition[CONDITION_VARIABLE, 1]
    return if name.nil?

    unless defined.include?(name)
      return add_warning(path, "undefined_variable", name,
                         "No question in this workflow sets #{name}. This branch will not " \
                         "fire unless the scenario supplies it.")
    end

    value = condition[CONDITION_STRING_VALUE, 1]
    values = options[name]
    return if value.nil? || values.nil? || values.include?(value)

    add_warning(path, "unmatched_option_value", value,
                "#{name} never takes the value #{value.inspect}. Its question offers: " \
                "#{values.join(', ')}.")
  end

  def supported_condition?(condition)
    STRICT_CONDITION_PATTERNS.any? { |pattern| pattern.match?(condition.to_s.strip) }
  end

  def defined_variables(steps)
    steps.filter_map { |step| step["variable_name"].presence }.to_set
  end

  def options_by_variable(steps)
    steps.each_with_object({}) do |step, map|
      next unless step["type"] == "question" && step["variable_name"].present?
      next unless step["options"].is_a?(Array)

      values = step["options"].filter_map { |o| o.is_a?(Hash) ? o["value"] : nil }
      map[step["variable_name"]] = values if values.any?
    end
  end

  def validate_interpolations(step, path, defined)
    step.each do |field, value|
      next unless value.is_a?(String)

      value.scan(INTERPOLATION).flatten.uniq.each do |name|
        next if defined.include?(name)

        add_warning("#{path}.#{field}", "undefined_variable", name,
                    "{{#{name}}} is not set by any question in this workflow. It will " \
                    "interpolate as empty unless the scenario supplies it.")
      end
    end
  end

  # --- graph -----------------------------------------------------------------

  # The same validator WorkflowPublisher#validate_ar_graph! runs, at the same
  # severity. The point of the dry run is that it says exactly what publish would
  # say — a validator that blesses files the app later rejects is worse than no
  # validator at all. Since the escapability rule replaced the acyclic check that
  # includes accepting loops: what GraphValidator refuses is a step with no path
  # to a Resolve, not a cycle as such.
  #
  # Runs on the normalized workflow, because GraphValidator reads target_uuid.
  def validate_graph(workflow)
    steps = workflow["steps"]
    keyed = steps.index_by { |step| step["id"] }
    start_id = workflow["start_step_id"] || steps.first["id"]

    validator = GraphValidator.new(keyed, start_id)
    return if validator.valid?

    validator.findings.each do |finding|
      add_error("workflows[0]", "graph_invalid", finding.code.to_s, finding.message)
    end
  end

  # --- structure -------------------------------------------------------------

  def validate_structure(workflow)
    validate_workflow_title(workflow)

    steps = workflow["steps"]
    unless steps.is_a?(Array) && steps.any?
      return add_error("workflows[0].steps", "envelope_invalid", nil,
                       "A workflow needs at least one step.")
    end

    seen_ids = {}

    steps.each_with_index do |step, index|
      path = "workflows[0].steps[#{index}]"
      unless step.is_a?(Hash)
        next add_error(path, "envelope_invalid", step.class.name,
                       "Each step must be an object.")
      end

      validate_step_id(step, path, seen_ids, index)
      type = validate_step_type(step, path)
      next if type.nil?

      validate_fields(step, type, path)
      validate_required(step, type, path)
      validate_enums(step, path)
      validate_step_transitions(step, type, path)
    end

    validate_transition_targets(steps, seen_ids.keys)
  end

  # Workflow validates title presence and a 255-character maximum. Without this
  # the dry run would report "valid" and the commit would then fail on an AR
  # validation, breaking the promise the report rests on: it says exactly what
  # committing would say.
  def validate_workflow_title(workflow)
    title = workflow["title"]

    if title.blank?
      add_error("workflows[0].title", "invalid_workflow_title", title,
                "A workflow needs a title.")
    elsif title.to_s.length > 255
      add_error("workflows[0].title", "invalid_workflow_title", title.to_s.truncate(60),
                "A workflow title is at most 255 characters; this one is #{title.to_s.length}.")
    end
  end

  def validate_step_id(step, path, seen_ids, index)
    id = step["id"]

    if id.blank?
      return add_error("#{path}.id", "missing_step_id", nil,
                       "Every step needs an id; transitions reference it.")
    end

    unless id.to_s.match?(step_id_pattern)
      return add_error("#{path}.id", "invalid_step_id", id,
                       "Step ids must be 1-64 characters of letters, digits, hyphen " \
                       "or underscore, starting with a letter or digit.")
    end

    if seen_ids.key?(id)
      add_error("#{path}.id", "duplicate_step_id", id,
                "Step id #{id.inspect} is already used by step #{seen_ids[id]} in this file.")
    else
      seen_ids[id] = index
    end
  end

  def validate_step_type(step, path)
    type = step["type"]
    return type if Workflow::VALID_STEP_TYPES.include?(type)

    add_error("#{path}.type", "unknown_step_type", type,
              "#{type.inspect} is not a step type.",
              expected: Workflow::VALID_STEP_TYPES)
  end

  def validate_fields(step, type, path)
    allowed = allowed_keys_for(type)

    step.each_key do |key|
      next if allowed.include?(key)

      if excluded_field_names.include?(key)
        add_error("#{path}.#{key}", "excluded_field", step[key],
                  "#{key} cannot be edited anywhere in the TurboFlows builder, so this " \
                  "dialect does not accept it — nobody could correct it afterwards.")
      else
        add_error("#{path}.#{key}", "unknown_field", step[key],
                  "#{key} is not a field on a #{type} step.", expected: allowed.sort)
      end
    end
  end

  def validate_required(step, type, path)
    schema_branch(type)["required"].each do |field|
      next if SELF_REPORTING_FIELDS.include?(field)
      next if step[field].present?

      add_error("#{path}.#{field}", "missing_required_field", nil,
                "A #{type} step needs #{field}.")
    end
  end

  def validate_enums(step, path)
    ImportSchemaGenerator::ENUMS.each do |field, values|
      value = step[field.to_s]
      next if value.blank?
      next if values.call.include?(value)

      add_error("#{path}.#{field}", "invalid_enum_value", value,
                "#{value.inspect} is not a valid #{field}.", expected: values.call)
    end
  end

  def validate_step_transitions(step, type, path)
    transitions = step["transitions"]

    if type == "resolve"
      if transitions.present?
        add_error("#{path}.transitions", "unexpected_transitions", transitions,
                  "A resolve step ends the workflow and must have no transitions.")
      end
      return
    end

    return if transitions.is_a?(Array) && transitions.any?

    add_error("#{path}.transitions", "missing_transitions", transitions,
              "Every step except resolve needs at least one transition. " \
              "This dialect does not infer them.")
  end

  def validate_transition_targets(steps, known_ids)
    steps.each_with_index do |step, index|
      next unless step.is_a?(Hash) && step["transitions"].is_a?(Array)

      step["transitions"].each_with_index do |transition, t_index|
        path = "workflows[0].steps[#{index}].transitions[#{t_index}].target_id"
        target = transition.is_a?(Hash) ? transition["target_id"] : nil
        next if known_ids.include?(target)

        add_error(path, "dangling_transition_target", target,
                  "No step in this file has id #{target.inspect}.")
      end
    end
  end

  # The dialect says target_id — an agent told "uuid" reaches for SecureRandom
  # instead of another step's id. WorkflowImporter reads target_uuid. Translate
  # once, here, so nothing downstream needs to know the wire name differs.
  def normalize(workflow)
    normalized = workflow.deep_dup
    Array(normalized["steps"]).each do |step|
      next unless step.is_a?(Hash) && step["transitions"].is_a?(Array)

      step["transitions"] = step["transitions"].map do |transition|
        transition.merge("target_uuid" => transition["target_id"]).except("target_id")
      end
    end
    normalized
  end

  def step_id_pattern
    @step_id_pattern ||= Regexp.new(ImportSchemaGenerator::STEP_ID_PATTERN)
  end

  def excluded_field_names
    @excluded_field_names ||= ImportSchemaGenerator::EXCLUDED_FIELDS.map(&:to_s) +
                              ImportSchemaGenerator::EXCLUDED_WIRE_KEYS
  end

  def allowed_keys_for(type)
    @allowed_keys ||= {}
    @allowed_keys[type] ||= schema_branch(type)["properties"].keys
  end

  def schema_branch(type)
    @schema ||= ImportSchemaGenerator.call
    @schema["$defs"]["step"]["oneOf"].find { |b| b["properties"]["type"]["const"] == type }
  end

  # --- reporting -------------------------------------------------------------

  # Always returns nil, so a caller can `return add_error(...)` to record and bail.
  def add_error(path, code, value, message, expected: nil)
    error = { path:, code:, message:, value: }
    error[:expected] = expected if expected
    @errors << error
    nil
  end

  def add_warning(path, code, value, message)
    @warnings << { path:, code:, message:, value: }
    nil
  end

  def report(workflow_data: nil, placement: nil)
    Report.new(errors: @errors, warnings: @warnings, workflow_data:, placement:)
  end
end
