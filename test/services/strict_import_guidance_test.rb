require "test_helper"

# A step's Guidance note (help_text) and Reference link (reference_url) went
# unchecked by the dry run: a javascript: link previewed as valid and was then
# refused at commit, and a note past the column's 500 characters previewed and
# committed on SQLite, where PostgreSQL would have raised instead. The report
# promises to say exactly what committing would say, so both are checked here.
class StrictImportGuidanceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "strict-guidance-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
  end

  teardown do
    Workflow.where(user: @user).destroy_all
    @user.destroy
  end

  test "a guidance note at the limit is valid and commits" do
    note = "x" * Step::HELP_TEXT_MAX_LENGTH
    report = validate(help_text: note)

    assert_predicate report, :valid?, report.errors.inspect
    assert_equal note, commit(report).workflow.steps.first.help_text
  end

  test "a guidance note past the limit is refused with its path and the limit" do
    report = validate(help_text: "x" * (Step::HELP_TEXT_MAX_LENGTH + 1))

    error = only_error(report)
    assert_equal "invalid_help_text", error[:code]
    assert_equal "workflows[0].steps[0].help_text", error[:path]
    assert_includes error[:message], Step::HELP_TEXT_MAX_LENGTH.to_s
    assert_includes error[:message], (Step::HELP_TEXT_MAX_LENGTH + 1).to_s
  end

  test "a guidance note that is not a string is refused" do
    assert_equal "invalid_help_text", only_error(validate(help_text: 42))[:code]
    assert_equal "invalid_help_text", only_error(validate(help_text: ["a"]))[:code]
  end

  %w[https://kb.example.com/a http://kb.example.com tel:+15551234567
     mailto:help@example.com /workflows/1].each do |url|
    test "the reference link #{url} is valid and commits" do
      report = validate(reference_url: url)

      assert_predicate report, :valid?, report.errors.inspect
      assert_equal url, commit(report).workflow.steps.first.reference_url
    end
  end

  {
    "javascript:alert(1)" => "http, https, tel, or mailto",
    "ftp://files.example.com" => "http, https, tel, or mailto",
    "not a url" => "not a valid URL"
  }.each do |url, reason|
    test "the reference link #{url} is refused by the dry run with the builder's reason" do
      error = only_error(validate(reference_url: url))

      assert_equal "invalid_reference_url", error[:code]
      assert_equal "workflows[0].steps[0].reference_url", error[:path]
      assert_equal url, error[:value]
      assert_includes error[:message], reason
    end
  end

  test "a reference link that is not a string is refused" do
    assert_equal "invalid_reference_url", only_error(validate(reference_url: 7))[:code]
  end

  test "a null or empty guidance note and reference link are fine" do
    assert_predicate validate(help_text: nil, reference_url: nil), :valid?
    assert_predicate validate(help_text: "", reference_url: ""), :valid?
  end

  private

  def validate(**fields)
    step = { id: "done", type: "resolve", title: "Done", resolution_type: "success", **fields }
    content = { schema_version: "1",
                workflows: [{ title: "Guidance #{SecureRandom.hex(3)}", steps: [step] }] }.to_json
    StrictImportValidator.new(user: @user, content:).validate
  end

  def commit(report)
    result = WorkflowImporter.new(@user, format: :json, content: "", strict_report: report).call
    assert_predicate result, :success?, result.errors.inspect
    result
  end

  def only_error(report)
    assert_equal 1, report.errors.size, report.errors.inspect
    report.errors.first
  end
end
