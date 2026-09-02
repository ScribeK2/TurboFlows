# Builds the JSON Schema an external AI agent validates against before it hands
# a file to a human to import.
#
# It reads StepFieldMap and the models' own VALID_* constants rather than
# restating them, because a hand-written schema is a sixth reader of knowledge
# that already disagreed across five (see StepFieldMap's own header). The schema
# is published for the agent only — the server validates by hand, in
# StrictImportValidator, because the checks that actually break imports (group
# permissions, dangling transitions, cycles, condition syntax) are outside what a
# schema can express.
class ImportSchemaGenerator
  SCHEMA_VERSION = "1".freeze
  SCHEMA_PATH = Rails.public_path.join("schemas/turboflows-workflow-v1.json")
  SCHEMA_URL = "/schemas/turboflows-workflow-v1.json".freeze

  # Importable but editable in no builder UI, so excluded from the dialect an
  # agent writes. See spec D9. (`variable_mapping` is deliberately NOT here — the
  # sub_flow editor does render it, in app/views/steps/fields/_sub_flow.html.erb.)
  EXCLUDED_FIELDS = %i[jumps output_fields action_type].freeze

  # Wire keys no agent can supply: a database id it has no way to know.
  EXCLUDED_WIRE_KEYS = %w[target_workflow_id].freeze

  STEP_ID_PATTERN = "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$".freeze

  # Fields that make a step of this type meaningful. Absence is a hard error.
  REQUIRED_BY_TYPE = {
    "question" => %w[question],
    "action" => %w[instructions],
    "message" => %w[content],
    "escalate" => %w[target_type],
    "resolve" => %w[resolution_type],
    "sub_flow" => %w[target_workflow_title],
    "form" => %w[options]
  }.freeze

  ENUMS = {
    answer_type: -> { Steps::Question::VALID_ANSWER_TYPES },
    target_type: -> { Steps::Escalate::VALID_TARGET_TYPES },
    priority: -> { Steps::Escalate::VALID_PRIORITIES },
    resolution_type: -> { Steps::Resolve::VALID_RESOLUTION_TYPES }
  }.freeze

  def self.call = new.call

  def call
    {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://turboflows.local#{SCHEMA_URL}",
      "title" => "TurboFlows workflow import",
      "type" => "object",
      "additionalProperties" => false,
      "required" => %w[schema_version workflows],
      "properties" => {
        "schema_version" => { "type" => "string", "enum" => [SCHEMA_VERSION] },
        "exported_at" => {
          "type" => "string",
          "description" => "Set by TurboFlows on export. Optional; ignored on import."
        },
        "workflows" => {
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 1,
          "description" => "This version accepts exactly one workflow per file.",
          "items" => { "$ref" => "#/$defs/workflow" }
        }
      },
      "$defs" => {
        "workflow" => workflow_def,
        "step" => { "oneOf" => Workflow::VALID_STEP_TYPES.map { |type| step_def(type) } },
        "transition" => transition_def,
        "group_path" => group_path_def
      }
    }
  end

  private

  def workflow_def
    {
      "type" => "object",
      "additionalProperties" => false,
      "required" => %w[title steps],
      "properties" => {
        "title" => { "type" => "string", "minLength" => 1, "maxLength" => 255 },
        "description" => { "type" => "string" },
        "start_step_id" => { "type" => "string", "pattern" => STEP_ID_PATTERN },
        "groups" => { "type" => "array", "items" => { "$ref" => "#/$defs/group_path" } },
        "folder" => { "type" => "string" },
        "tags" => { "type" => "array", "items" => { "type" => "string" } },
        "steps" => { "type" => "array", "minItems" => 1, "items" => { "$ref" => "#/$defs/step" } }
      }
    }
  end

  def group_path_def
    {
      "description" => 'Either "Support / Tier 2" or ["Support", "Tier 2"]. ' \
                       "Use the array form when a group name contains a slash.",
      "oneOf" => [
        { "type" => "string", "minLength" => 1 },
        { "type" => "array", "minItems" => 1, "items" => { "type" => "string", "minLength" => 1 } }
      ]
    }
  end

  def step_def(type)
    properties = common_properties.merge(type_properties(type))
    properties["transitions"] = transitions_property unless type == "resolve"

    {
      "type" => "object",
      "additionalProperties" => false,
      "required" => required_for(type),
      "properties" => properties.merge("type" => { "const" => type })
    }
  end

  def common_properties
    {
      "id" => { "type" => "string", "pattern" => STEP_ID_PATTERN },
      "title" => { "type" => "string", "minLength" => 1 },
      "help_text" => { "type" => "string", "maxLength" => 500 },
      "reference_url" => { "type" => "string", "format" => "uri" }
    }
  end

  def type_properties(type)
    fields = StepFieldMap.plain_fields(type) - StepFieldMap::COMMON - EXCLUDED_FIELDS
    fields += StepFieldMap.rich_text_fields(type) - EXCLUDED_FIELDS

    fields.index_with { |field| property_for(field) }
          .transform_keys { |field| StepFieldMap.wire_key(field).to_s }
          .except(*EXCLUDED_WIRE_KEYS)
          .merge(sub_flow_properties(type))
  end

  # sub_flow's column is sub_flow_workflow_id, whose wire key is
  # target_workflow_id — a database id no external agent can know. The dialect
  # takes a title instead, and StrictImportValidator resolves it (Task 7).
  #
  # The `except` above is load-bearing: `transform_keys` has already produced a
  # "target_workflow_id" property by this point, so removing it from the merged
  # hash is not enough — it has to come out of the transformed hash itself.
  def sub_flow_properties(type)
    return {} unless type == "sub_flow"

    { "target_workflow_title" => { "type" => "string", "minLength" => 1 } }
  end

  def property_for(field)
    return { "type" => "string", "enum" => ENUMS[field].call } if ENUMS.key?(field)

    case field
    when :options then options_property
    when :variable_mapping then { "type" => "object" }
    when :can_resolve, :reason_required, :notes_required, :survey_trigger
      { "type" => "boolean" }
    when :instructions, :content, :notes, :description
      { "type" => "string",
        "description" => "HTML. Use <p>, <strong>, <em>, <ul>/<ol>/<li>, <a>. " \
                         "Markdown is NOT converted and will render literally." }
    else { "type" => "string" }
    end
  end

  # `options` means two different things: answer choices on question, and field
  # definitions on form.
  def options_property
    {
      "type" => "array",
      "items" => {
        "oneOf" => [
          { "type" => "object", "additionalProperties" => false,
            "required" => %w[label value],
            "properties" => { "label" => { "type" => "string" },
                              "value" => { "type" => "string" } } },
          { "type" => "object", "additionalProperties" => false,
            "required" => %w[name label],
            "properties" => {
              "name" => { "type" => "string" },
              "label" => { "type" => "string" },
              "field_type" => { "type" => "string", "enum" => Steps::Form::VALID_FIELD_TYPES },
              "required" => { "type" => "boolean" },
              "position" => { "type" => "integer" }
            } }
        ]
      }
    }
  end

  def transitions_property
    { "type" => "array", "minItems" => 1, "items" => { "$ref" => "#/$defs/transition" } }
  end

  def transition_def
    {
      "type" => "object",
      "additionalProperties" => false,
      "required" => %w[target_id],
      "properties" => {
        "target_id" => { "type" => "string", "pattern" => STEP_ID_PATTERN },
        "label" => { "type" => "string" },
        "condition" => {
          "type" => "string",
          "description" => "One comparison only. Supported forms: " \
                           "var == 'value', var != 'value', var > 10, var >= 10, " \
                           "var < 10, var <= 10. No && or ||. Numbers must be " \
                           "whole and positive."
        }
      }
    }
  end

  def required_for(type)
    (%w[id type title] + REQUIRED_BY_TYPE.fetch(type, []) +
      (type == "resolve" ? [] : %w[transitions])).uniq
  end
end
