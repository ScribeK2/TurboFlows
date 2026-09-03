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
end
