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

  private

  def step_branch(type)
    @schema["$defs"]["step"]["oneOf"].find { |b| b["properties"]["type"]["const"] == type }
  end
end
