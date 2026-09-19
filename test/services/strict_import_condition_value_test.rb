require "test_helper"

# StrictImportValidator's "unmatched option value" check, which used to read a
# condition's value with its own regex (`CONDITION_STRING_VALUE`). That regex
# could not follow an escaped quote or backslash, so once ConditionEvaluator's
# grammar became escape-aware (2026-09-19), a condition a grown door actually
# writes — `choice == 'Don\'t know'` — extracted "Don\" and warned against a
# real option. The check now reads the value through
# ConditionEvaluator#parse, the same tokenizer the runner uses.
class StrictImportConditionValueTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "strict-condval-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!",
                         role: "editor")
  end

  teardown do
    User.where("email LIKE ?", "strict-condval-%").destroy_all
  end

  test "an escaped apostrophe matching a real option raises neither an error nor a warning" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Known?", question: "Is it known?",
                                        answer_type: "dropdown", variable_name: "choice",
                                        options: [{ label: "Don't know", value: "Don't know" },
                                                  { label: "Router", value: "router" }],
                                        transitions: [{ target_id: "done", condition: "choice == 'Don\\'t know'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_not_includes report.errors.pluck(:code), "invalid_condition_syntax"
    assert_not_includes report.warnings.pluck(:code), "unmatched_option_value"
  end

  test "an old-style condition with a bare backslash matching its option raises no warning" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Drive?", question: "Which drive?",
                                        answer_type: "dropdown", variable_name: "path",
                                        options: [{ label: "C Drive", value: 'C:\temp' },
                                                  { label: "Router", value: "router" }],
                                        transitions: [{ target_id: "done", condition: "path == 'C:\\temp'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_not_includes report.warnings.pluck(:code), "unmatched_option_value"
  end

  test "a new-style condition with an escaped backslash matching its option raises no warning" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Drive?", question: "Which drive?",
                                        answer_type: "dropdown", variable_name: "path",
                                        options: [{ label: "C Drive", value: 'C:\temp' },
                                                  { label: "Router", value: "router" }],
                                        transitions: [{ target_id: "done", condition: "path == 'C:\\\\temp'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_not_includes report.warnings.pluck(:code), "unmatched_option_value"
  end

  # The legacy shape ConditionEvaluator's tokenizer still cannot close (the
  # trailing backslash would consume the closing quote as an escape), so
  # #parse falls back to the split-based reader — same as it always has.
  test "a condition ending in a bare backslash matching its option raises no warning" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Drive?", question: "Which drive?",
                                        answer_type: "dropdown", variable_name: "path",
                                        options: [{ label: "C Drive", value: 'C:\\' },
                                                  { label: "Router", value: "router" }],
                                        transitions: [{ target_id: "done", condition: "path == 'C:\\'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_not_includes report.warnings.pluck(:code), "unmatched_option_value"
  end

  test "a genuinely unmatched escaped value is warned, quoting the value as written" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Known?", question: "Is it known?",
                                        answer_type: "dropdown", variable_name: "choice",
                                        options: [{ label: "Router", value: "router" }],
                                        transitions: [{ target_id: "done", condition: "choice == 'Don\\'t know'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    warning = report.warnings.find { |w| w[:code] == "unmatched_option_value" }
    assert_not_nil warning
    literal_as_written = "Don\\'t know"
    assert_equal literal_as_written, warning[:value]
    assert_includes warning[:message], literal_as_written.inspect
  end

  test "mismatched delimiters are refused as an invalid condition, not read as a value" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Known?", question: "Is it known?",
                                        answer_type: "dropdown", variable_name: "choice",
                                        options: [{ label: "Yes", value: "yes" }],
                                        transitions: [{ target_id: "done", condition: %(choice == 'yes") }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "invalid_condition_syntax" }
    assert_not_nil error
    assert_includes error[:message], "a quote inside a value is escaped as \\'"
  end

  # options[name] is read straight off the JSON file's "value" key with no type
  # coercion (see the schema, which asks for a string but nothing here enforces
  # it), so an agent-written numeric option can arrive as a JSON number. Without
  # this the String parsed[:value] would never == that Integer, and a perfectly
  # matching numeric option would be reported as unmatched.
  test "a numeric-looking value is not checked against options, avoiding a JSON number/string false positive" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Attempts?", question: "How many?",
                                        answer_type: "dropdown", variable_name: "attempts",
                                        options: [{ label: "One", value: 1 }, { label: "Two", value: 2 }],
                                        transitions: [{ target_id: "done", condition: "attempts == '1'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_not_includes report.warnings.pluck(:code), "unmatched_option_value"
  end

  private

  def validate(hash)
    StrictImportValidator.new(user: @user, content: hash.to_json).validate
  end

  def document_with(steps:)
    { schema_version: "1", workflows: [{ title: "Condition Values", steps: }] }
  end

  def resolve_step
    { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
  end
end
