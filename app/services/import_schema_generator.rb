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

  # How many workflows one file may carry.
  #
  # Was 1, which meant a set of linked workflows could not be expressed at all:
  # a sub_flow target has to name a workflow that already exists AND is
  # published, so a five-workflow domain took nine operations in an order the
  # operator had to derive. Raising it is backward compatible — a one-workflow
  # file still validates — and it is what lets a generated set arrive as one
  # deliverable.
  #
  # Capped rather than unbounded: the whole bundle is validated and written in
  # one transaction, and the 10MB upload limit is a poor proxy for how much work
  # that is. Twenty-five is well past any real domain and still bounded.
  MAX_WORKFLOWS_PER_FILE = 25

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
          "maxItems" => MAX_WORKFLOWS_PER_FILE,
          "description" => "One or more workflows, up to #{MAX_WORKFLOWS_PER_FILE}. " \
                           "They are imported together as one set, so a sub_flow step may " \
                           "name a workflow defined elsewhere in this same file by its " \
                           "title — it does not have to exist or be published first.",
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

    definition = {
      "type" => "object",
      "additionalProperties" => false,
      "required" => required_for(type),
      "properties" => properties.merge("type" => { "const" => type })
    }
    definition["allOf"] = [handoff_transitions_rule] if type == "sub_flow"
    definition
  end

  # A sub_flow's transitions are required only when it returns.
  #
  # `transitions` used to be required for every non-resolve type, with
  # `minItems: 1` on the property, so the published schema forbade the exact
  # shape this feature exists to let an agent emit — a step that hands the run
  # over and therefore ends the workflow.
  #
  # Expressed as a condition rather than by dropping the requirement, because a
  # RETURNING sub_flow with nowhere to go is still the dangling step the rule was
  # written for. The `else` is what keeps that true.
  def handoff_transitions_rule
    {
      "if" => {
        "properties" => { "sub_flow_returns" => { "const" => false } },
        "required" => %w[sub_flow_returns]
      },
      "then" => { "not" => { "required" => %w[transitions] } },
      "else" => { "required" => %w[transitions] }
    }
  end

  def common_properties
    {
      "id" => { "type" => "string", "pattern" => STEP_ID_PATTERN },
      "title" => { "type" => "string", "minLength" => 1 },
      "help_text" => { "type" => "string", "maxLength" => Step::HELP_TEXT_MAX_LENGTH },
      "reference_url" => { "type" => "string", "format" => "uri" }
    }
  end

  def type_properties(type)
    fields = StepFieldMap.plain_fields(type) - StepFieldMap::COMMON - EXCLUDED_FIELDS
    fields += StepFieldMap.rich_text_fields(type) - EXCLUDED_FIELDS

    fields.index_with { |field| property_for(field, type) }
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

  def property_for(field, type)
    return { "type" => "string", "enum" => ENUMS[field].call } if ENUMS.key?(field)

    case field
    when :options then options_property(type)
    when :variable_mapping then variable_mapping_property
    when :can_resolve, :reason_required, :notes_required, :survey_trigger
      { "type" => "boolean" }
    when :sub_flow_returns
      { "type" => "boolean",
        "description" => "Default true: the sub-flow runs and the agent comes back here. " \
                         "Set false to hand the run over for good — the step then ends this " \
                         "workflow, so it takes no transitions and needs no Resolve after it." }
    when :instructions, :content, :notes, :description
      { "type" => "string",
        "description" => "HTML. Use <p>, <strong>, <em>, <ul>/<ol>/<li>, <a>. " \
                         "Markdown is NOT converted and will render literally." }
    else { "type" => "string" }
    end
  end

  # `options` means two different things depending on step type: answer choices
  # on a question, field definitions on a form. Each branch publishes its own
  # shape, with no `oneOf` — a single shared shape let an agent write
  # Form-shaped options on a Question step (or the reverse) and validate
  # cleanly, which defeats the point of validating against this schema at all.
  def options_property(type)
    case type
    when "question" then question_options_property
    when "form" then form_options_property
    end
  end

  def question_options_property
    {
      "type" => "array",
      "items" => {
        "type" => "object",
        "additionalProperties" => false,
        "required" => %w[label value],
        "properties" => {
          "label" => { "type" => "string" },
          "value" => { "type" => "string" }
        }
      }
    }
  end

  def form_options_property
    {
      "type" => "array",
      "items" => {
        "type" => "object",
        "additionalProperties" => false,
        "required" => %w[name label],
        "properties" => {
          "name" => { "type" => "string" },
          "label" => { "type" => "string" },
          "field_type" => { "type" => "string", "enum" => Steps::Form::VALID_FIELD_TYPES },
          "required" => { "type" => "boolean" },
          "position" => { "type" => "integer" },
          "select_options" => select_options_property
        },
        # StrictImportValidator makes a choiceless select a hard error, and the
        # prompt tells the agent to validate against this schema before handing
        # the file over. A schema looser than the validator sends it away with a
        # file that passes locally and is refused on upload — the round trip the
        # strict dialect exists to remove.
        "allOf" => [
          {
            "if" => {
              "properties" => { "field_type" => { "const" => "select" } },
              "required" => %w[field_type]
            },
            "then" => { "required" => %w[select_options] }
          }
        ]
      }
    }
  end

  # Which of this run's variables the sub-flow can see, and what it calls them.
  #
  # Published as a bare `{"type" => "object"}` until 2026-09-04, with one word
  # in the prompt and no description here. An agent authoring against the schema
  # could not tell the direction, so it omitted the key entirely and every
  # generated sub-flow re-asked for data the parent had already collected.
  # The direction is `{parent_name => child_name}` — see
  # ScenarioStepProcessor#process_subflow_step, which seeds
  # `child_results[child_var] = @scenario.results[parent_var]`.
  def variable_mapping_property
    {
      "type" => "object",
      "description" => "Renames a variable for the sub-flow, as " \
                       '{"name_in_this_workflow": "name_inside_the_sub_flow"}. ' \
                       "A sub-flow already inherits every variable collected so far " \
                       "under its original name, so a mapping is only needed when the " \
                       "sub-flow refers to one by a different name.",
      "additionalProperties" => { "type" => "string" }
    }
  end

  # The choice list for a field of type "select". Same {label, value} shape a
  # question's options use, because it is the same idea one level down.
  #
  # Its absence is what made `field_type: "select"` unusable: the enum accepted
  # it, and there was nowhere to say what the choices were, so it imported as a
  # dropdown with no entries.
  def select_options_property
    {
      "type" => "array",
      "minItems" => 1,
      "description" => 'Choices for a field whose field_type is "select". ' \
                       "Required for select, meaningless on any other type.",
      "items" => {
        "type" => "object",
        "additionalProperties" => false,
        "required" => %w[label value],
        "properties" => {
          "label" => { "type" => "string" },
          "value" => { "type" => "string" }
        }
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

  # sub_flow is excluded here and handled by handoff_transitions_rule instead:
  # whether it needs transitions depends on the value of sub_flow_returns, which
  # a flat required list cannot express.
  def required_for(type)
    unconditional_transitions = %w[resolve sub_flow].exclude?(type)

    (%w[id type title] + REQUIRED_BY_TYPE.fetch(type, []) +
      (unconditional_transitions ? %w[transitions] : [])).uniq
  end
end
