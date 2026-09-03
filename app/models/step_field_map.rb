# frozen_string_literal: true

# Which fields belong to which step type. One declaration, five readers.
#
# The map used to be written out longhand in every reader — StepBuilder,
# StepsController#step_params, StepSerializer, WorkflowImporter and
# WorkflowParsers::StepNormalizer — and they disagreed. Adding a field meant
# editing five files; nobody edits five, so fields were dropped at whichever
# reader was missed. That is not a tidiness problem: StepSerializer builds the
# snapshot WorkflowPublisher stores, and WorkflowVersionsController#restore
# feeds that snapshot back through StepBuilder with `replace: true`. A field
# missing from the serializer is erased from the workflow when someone restores
# a version.
#
# This module owns *which*. It deliberately does not own *how*: the permit list
# needs nested shapes, the serializer needs `&.body&.to_html.to_s` (Content#to_s
# renders through the app's display layout, which re-wraps on every publish or
# export cycle — see StepSerializer#rich_text_html) and presence guards, and the
# parser keeps its import-dialect tolerances. Unifying the mechanics as well
# turns a tractable change into a rewrite of five subtle readers.
#
# The guarantee lives in test/services/step_field_map_test.rb, which populates
# every field of every type and asserts it survives publish/restore,
# export/import and a controller PATCH. Assert behaviour there, not this
# declaration — the test stays true however the readers are refactored.
module StepFieldMap
  # Carried by every step, whatever its type.
  COMMON = %i[title position help_text reference_url].freeze

  # Plain (non-Action-Text) attributes, by step type.
  BY_TYPE = {
    "question" => %i[question answer_type variable_name options can_resolve],
    "action" => %i[action_type can_resolve output_fields jumps],
    "message" => %i[can_resolve jumps],
    "escalate" => %i[target_type target_value priority reason_required],
    "resolve" => %i[resolution_type resolution_code notes_required survey_trigger],
    "sub_flow" => %i[sub_flow_workflow_id variable_mapping],
    "form" => %i[options]
  }.freeze

  # Action Text bodies. They cannot be assigned in the same breath as the
  # columns above — the record has to exist first — so every reader handles
  # them separately, which is exactly how `description` came to be rendered by
  # the Resolve editor and permitted by nobody.
  RICH_TEXT = {
    "action" => %i[instructions],
    "message" => %i[content],
    "escalate" => %i[notes],
    "resolve" => %i[description],
    "form" => %i[instructions]
  }.freeze

  # Where the serialized name differs from the column name. Export files and
  # imports in the wild carry the wire key, so a reader that derives from this
  # map must translate rather than assume the column name.
  WIRE_ALIASES = { sub_flow_workflow_id: :target_workflow_id }.freeze

  # Strong-params shapes for anything that is not a scalar.
  #
  # `options` is the union of two shapes, deliberately. It means answer choices
  # on a question ({label, value}) and field definitions on a form ({name, label,
  # field_type, required, position}), and `permit` cannot vary a nested shape by
  # step type at this level. Permitting only the question shape silently stripped
  # every form field's name, type and required flag on save — the builder kept
  # the label and nothing else. Permitting a key is not requiring it, so a
  # question's options are unaffected.
  #
  # The schema published to external agents does distinguish the two, per type —
  # see ImportSchemaGenerator#question_options_property / #form_options_property.
  # The union here is a strong-params limitation, not the domain truth.
  #
  # `jumps` is an Array of {condition, next_step_id}: StepResolver#check_jumps
  # returns nil for anything that is not an Array, and the import normalizer
  # only preserves Arrays. It was declared here as a bare hash, which would have
  # filtered a real array away — latent rather than live, since no UI authors
  # jumps yet.
  NESTED_SHAPES = {
    options: [%i[label value name field_type required position]],
    output_fields: [%i[name value]],
    jumps: [%i[condition next_step_id]],
    variable_mapping: {}
  }.freeze

  # Deliberately absent, so the next reader does not "fix" them back in:
  #
  # - `position_x` / `position_y` — canvas coordinates for the visual editor,
  #   whose JS was deleted in f8240c05 and whose remaining partials and helper
  #   went in cca393f9. StepBuilder still assigns them and nothing reads them.
  #   Vestigial columns now, with no reader left to justify mapping them.
  # - `resolution_notes` — emitted by the parser's normalizer for resolve steps,
  #   but it is not a step field at all: it is a transient *scenario* input
  #   (Scenario::TRANSIENT_INPUT_KEYS), read at run time from scenario.inputs.
  #   Nothing reads it off a Step.
  # - `target_workflow_title` — import dialect, not a column. base_parser
  #   resolves it into target_workflow_id before the importer runs.
  # - `transitions` — edges, not step attributes. Every reader handles them
  #   separately and they have their own shape.

  class << self
    def types = BY_TYPE.keys

    def plain_fields(type) = COMMON + BY_TYPE.fetch(type.to_s, [])

    def rich_text_fields(type) = RICH_TEXT.fetch(type.to_s, [])

    def all_fields(type) = plain_fields(type) + rich_text_fields(type)

    # Every plain field any type can carry, for a permit list.
    def all_plain_fields = (COMMON + BY_TYPE.values.flatten).uniq

    def all_rich_text_fields = RICH_TEXT.values.flatten.uniq

    # Scalars only — the nested ones need their shape, not a bare symbol.
    def scalar_fields = all_plain_fields - NESTED_SHAPES.keys

    def wire_key(field) = WIRE_ALIASES.fetch(field.to_sym, field.to_sym)
  end
end
