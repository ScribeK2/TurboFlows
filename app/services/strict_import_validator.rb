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

    validate_structure(workflow)
    return report if @errors.any?

    normalized = normalize(workflow)
    validate_graph(normalized)

    report(workflow_data: normalized)
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
