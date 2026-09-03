require "test_helper"

class StrictImportValidatorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "strict-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  teardown { User.where("email LIKE ?", "strict-test-%").destroy_all }

  test "a file with schema_version is the strict dialect" do
    assert StrictImportValidator.strict?('{"schema_version":"1","workflows":[]}')
  end

  test "a file without schema_version is not" do
    assert_not StrictImportValidator.strict?('{"title":"Legacy","steps":[]}')
  end

  test "non-JSON is not the strict dialect" do
    assert_not StrictImportValidator.strict?("workflow_title,step_number\nA,1\n")
  end

  test "an unsupported schema_version is a hard error naming what is supported" do
    report = validate({ schema_version: "99", workflows: [] })

    assert_not report.valid?
    error = report.errors.first
    assert_equal "unsupported_schema_version", error[:code]
    assert_equal "schema_version", error[:path]
    assert_equal "99", error[:value]
    assert_equal [ImportSchemaGenerator::SCHEMA_VERSION], error[:expected]
  end

  test "a missing workflows array is an envelope error" do
    report = validate({ schema_version: "1" })

    assert_not report.valid?
    assert_equal "envelope_invalid", report.errors.first[:code]
  end

  test "more than one workflow is refused with a message that says why" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow, minimal_workflow] })

    assert_not report.valid?
    assert_equal "envelope_invalid", report.errors.first[:code]
    assert_match(/one workflow per file/, report.errors.first[:message])
  end

  test "malformed JSON is reported, not raised" do
    report = StrictImportValidator.new(user: @user, content: "{ nope").validate

    assert_not report.valid?
    assert_equal "malformed_json", report.errors.first[:code]
  end

  test "a minimal valid file passes" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow] })

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "an unknown step type is refused with the valid list" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "decision", title: "Branch", transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "unknown_step_type" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].type", error[:path]
    assert_equal "decision", error[:value]
    assert_equal Workflow::VALID_STEP_TYPES, error[:expected]
  end

  test "a duplicate step id is refused" do
    report = validate(document_with(steps: [
                                      { id: "dup", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      { id: "dup", type: "message", title: "Two", content: "<p>b</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "duplicate_step_id" }
    assert_not_nil error
    assert_equal "workflows[0].steps[1].id", error[:path]
    assert_equal "dup", error[:value]
  end

  test "a missing step id is refused" do
    report = validate(document_with(steps: [
                                      { type: "message", title: "No id", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_includes report.errors.pluck(:code), "missing_step_id"
  end

  test "a step id with illegal characters is refused" do
    report = validate(document_with(steps: [
                                      { id: "not a slug!", type: "message", title: "Bad id", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "invalid_step_id" }
    assert_not_nil error
    assert_equal "not a slug!", error[:value]
  end

  test "an unknown field is refused rather than dropped" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "Extra", content: "<p>a</p>",
                                        colour: "blue", transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "unknown_field" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].colour", error[:path]
  end

  test "a field with no builder UI is refused with an explanation" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "action", title: "Jumper", instructions: "<p>a</p>",
                                        jumps: [{ condition: "x == '1'", next_step_id: "done" }],
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "excluded_field" }
    assert_not_nil error
    assert_match(/cannot be edited/, error[:message])
  end

  test "a missing required field for the type is refused" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "question", title: "No question text",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "missing_required_field" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].question", error[:path]
  end

  test "a non-resolve step without transitions is refused, not auto-wired" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "Dangling", content: "<p>a</p>" },
                                      resolve_step
                                    ]))

    assert_includes report.errors.pluck(:code), "missing_transitions"
  end

  test "a resolve step with transitions is refused" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      { id: "done", type: "resolve", title: "Done", resolution_type: "success",
                                        transitions: [{ target_id: "s1" }] }
                                    ]))

    assert_includes report.errors.pluck(:code), "unexpected_transitions"
  end

  test "a transition to a nonexistent step is refused, not silently dropped" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "nowhere" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "dangling_transition_target" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].transitions[0].target_id", error[:path]
    assert_equal "nowhere", error[:value]
  end

  test "an enum value outside the model's list is refused" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "question", title: "Q", question: "Which?",
                                        answer_type: "telepathy", transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "invalid_enum_value" }
    assert_not_nil error
    assert_equal Steps::Question::VALID_ANSWER_TYPES, error[:expected]
  end

  test "a blank workflow title is caught by the dry run, not at commit time" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1", workflows: [{ title: "", steps: [resolve_step] }]
    }.to_json).validate

    assert_not report.valid?
    error = report.errors.find { |e| e[:code] == "invalid_workflow_title" }
    assert_not_nil error
    assert_equal "workflows[0].title", error[:path]
  end

  test "an over-long workflow title is caught by the dry run" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1", workflows: [{ title: "x" * 256, steps: [resolve_step] }]
    }.to_json).validate

    assert_not report.valid?
    assert_includes report.errors.pluck(:code), "invalid_workflow_title"
  end

  test "a valid file's transitions are handed on as target_uuid" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_equal "done", report.workflow_data["steps"][0]["transitions"][0]["target_uuid"]
  end

  private

  def validate(hash)
    StrictImportValidator.new(user: @user, content: hash.to_json).validate
  end

  def minimal_workflow
    {
      title: "Minimal",
      steps: [{ id: "done", type: "resolve", title: "Done", resolution_type: "success" }]
    }
  end

  def document_with(steps:)
    { schema_version: "1", workflows: [{ title: "Structural", steps: }] }
  end

  def resolve_step
    { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
  end
end
