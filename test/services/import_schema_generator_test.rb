require "test_helper"

class ImportSchemaGeneratorTest < ActiveSupport::TestCase
  setup { @schema = ImportSchemaGenerator.call }

  test "the envelope requires schema_version and a one-element workflows array" do
    assert_equal %w[schema_version workflows], @schema["required"]
    # The app's own export sets exported_at; additionalProperties is false, so an
    # agent validating against this schema would otherwise reject a TurboFlows export.
    assert @schema["properties"].key?("exported_at")
    assert_equal [ImportSchemaGenerator::SCHEMA_VERSION],
                 @schema["properties"]["schema_version"]["enum"]
    assert_equal 1, @schema["properties"]["workflows"]["maxItems"]
    assert_equal 1, @schema["properties"]["workflows"]["minItems"]
  end

  test "every step type in the app has a schema branch" do
    branch_types = @schema["$defs"]["step"]["oneOf"].map do |branch|
      branch["properties"]["type"]["const"]
    end

    assert_equal Workflow::VALID_STEP_TYPES.sort, branch_types.sort
  end

  test "step branches publish the model's own value lists" do
    question = step_branch("question")

    assert_equal Steps::Question::VALID_ANSWER_TYPES,
                 question["properties"]["answer_type"]["enum"]

    escalate = step_branch("escalate")

    assert_equal Steps::Escalate::VALID_PRIORITIES,
                 escalate["properties"]["priority"]["enum"]
    assert_equal Steps::Escalate::VALID_TARGET_TYPES,
                 escalate["properties"]["target_type"]["enum"]

    resolve = step_branch("resolve")

    assert_equal Steps::Resolve::VALID_RESOLUTION_TYPES,
                 resolve["properties"]["resolution_type"]["enum"]
  end

  test "fields with no builder UI are absent from every branch" do
    excluded = ImportSchemaGenerator::EXCLUDED_FIELDS.map(&:to_s) +
               ImportSchemaGenerator::EXCLUDED_WIRE_KEYS

    excluded.each do |field|
      @schema["$defs"]["step"]["oneOf"].each do |branch|
        assert_not branch["properties"].key?(field),
                   "#{field} leaked into the #{branch['properties']['type']['const']} branch"
      end
    end
  end

  test "sub_flow takes a workflow title, never a database id" do
    sub_flow = step_branch("sub_flow")

    assert sub_flow["properties"].key?("target_workflow_title")
    assert_includes sub_flow["required"], "target_workflow_title"
  end

  test "variable_mapping is published, because the sub_flow editor renders it" do
    assert step_branch("sub_flow")["properties"].key?("variable_mapping")
  end

  test "every step branch forbids additional properties" do
    @schema["$defs"]["step"]["oneOf"].each do |branch|
      assert_not branch.fetch("additionalProperties")
    end
  end

  test "resolve steps are forbidden transitions and others require them" do
    assert_not step_branch("resolve")["properties"].key?("transitions")
    assert_includes step_branch("action")["required"], "transitions"
  end

  test "the committed schema file matches the generator" do
    committed = JSON.parse(File.read(ImportSchemaGenerator::SCHEMA_PATH))

    assert_equal @schema, committed,
                 "public/schemas is stale — run `bin/rails import_schema:generate`"
  end

  # `options` means two different things depending on step type: answer
  # choices on a question, field definitions on a form. Before this fix, both
  # branches published the same shared `oneOf`, so an agent could write
  # Form-shaped options on a Question step and validate cleanly. These three
  # tests pin the two shapes apart, using a minimal structural check (below)
  # rather than a real JSON Schema validator, since none is a project dependency.
  test "question options reject a form-shaped hash and accept its own shape" do
    item_schema = step_branch("question")["properties"]["options"]["items"]

    assert_not schema_permits?(item_schema, { "name" => "phone", "label" => "Phone" }),
               "question options accepted a form-shaped {name, label} hash"
    assert schema_permits?(item_schema, { "label" => "Yes", "value" => "yes" })
  end

  test "form options reject a bare label/value hash and accept its own shape" do
    item_schema = step_branch("form")["properties"]["options"]["items"]

    assert_not schema_permits?(item_schema, { "label" => "Yes", "value" => "yes" }),
               "form options accepted a bare question-shaped {label, value} hash"
    assert schema_permits?(item_schema, { "name" => "phone", "label" => "Phone" })
  end

  test "question and form options schemas are not the same shape" do
    assert_not_equal step_branch("question")["properties"]["options"],
                     step_branch("form")["properties"]["options"]
  end

  private

  def step_branch(type)
    @schema["$defs"]["step"]["oneOf"].find { |b| b["properties"]["type"]["const"] == type }
  end

  # Minimal object-schema check: required keys present, and — when
  # additionalProperties is false — no keys outside the declared properties.
  # Not a general JSON Schema validator, just enough to prove the two options
  # branches genuinely reject each other's hash shape rather than merely
  # differing in some property that neither shape's `required`/`additionalProperties`
  # actually enforces.
  def schema_permits?(item_schema, hash)
    return false unless (item_schema.fetch("required", []) - hash.keys).empty?
    return true unless item_schema["additionalProperties"] == false

    (hash.keys - item_schema["properties"].keys).empty?
  end
end
