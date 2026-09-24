require "test_helper"

class ImportPromptGeneratorTest < ActiveSupport::TestCase
  setup { @prompt = ImportPromptGenerator.call }

  test "the prompt names every step type" do
    Workflow::VALID_STEP_TYPES.each { |type| assert_includes @prompt, type }
  end

  test "the prompt states that rich text is HTML, not Markdown" do
    assert_match(/HTML/, @prompt)
    assert_match(/Markdown is not converted/i, @prompt)
  end

  test "the prompt lists the supported condition forms" do
    assert_includes @prompt, "var == 'value'"
  end

  # The strict validator now reads a condition's value through
  # ConditionEvaluator#parse, which understands an escaped quote — the prompt
  # has to say so, or an agent has nowhere to learn it (2026-09-19).
  test "the prompt says a quote inside a value is escaped, with exactly one backslash rendered" do
    line = @prompt.lines.find { |l| l.include?("A quote inside a value") }
    assert_not_nil line, "the prompt is missing the escaping rule"
    assert_includes line, "\\'"
    assert_equal 2, line.count("\\"), "one backslash in the rule, one in the worked example"
  end

  test "the prompt says loops are allowed and what makes one invalid" do
    assert_match(/Loops are allowed/i, @prompt)
    assert_match(/reach a `resolve` step/i, @prompt)
  end

  # The one that matters. A prompt containing an example that does not import is
  # worse than no prompt: it teaches the agent a format the app rejects.
  test "the worked example in the prompt actually validates" do
    example = @prompt[/```json\n(.*?)```/m, 1]
    assert_predicate example, :present?, "no json fence found in the prompt"

    user = User.create!(
      email: "prompt-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    report = StrictImportValidator.new(user:, content: example).validate

    assert_predicate report, :valid?, report.errors.inspect
    assert_empty report.warnings, report.warnings.inspect
  ensure
    User.where("email LIKE ?", "prompt-test-%").destroy_all
  end

  # `"groups": ["Support", "Tier 2"]` is two root lookups, not one nested path.
  # The prompt used to teach that shape as the slash-escape, so an agent that
  # followed it would land the parent and fail the child as unknown_group.
  test "the prompt does not teach a flat two-string groups array as one path" do
    assert_includes @prompt, '"groups": [["Support", "Tier 2"]]'
    assert_no_match(/Use `\["Support", "Tier 2"\]`/, @prompt)
  end

  test "the prompt states the sub-flow graph rules" do
    assert_match(/hand off to each other/i, @prompt)
    assert_includes @prompt, "chain of handoffs"
    assert_includes @prompt, "eventually"
    assert_includes @prompt, "reaches"
    assert_includes @prompt, "#{SubflowValidator::MAX_DEPTH} levels deep"
  end

  # StrictImportValidator refuses a transition listed after one with no
  # condition (shadowed_transition); an agent has nowhere else to learn why.
  test "the prompt says transitions are tried in order and the default goes last" do
    assert_match(/first one that matches wins/i, @prompt)
    assert_match(/no `condition`.*last/im, @prompt)
  end

  # The prompt named `help_text` and `reference_url` and nothing more, so an
  # agent had no way to know they are the builder's Guidance note and
  # Reference link, or when a step wants one.
  test "the prompt says what help_text and reference_url are for" do
    line = @prompt.lines.find { |l| l.include?("`help_text`") && l.include?("Guidance") }
    assert_not_nil line, "help_text is not tied to the Guidance note"
    assert_includes line, "#{Step::HELP_TEXT_MAX_LENGTH} characters"
    assert @prompt.lines.any? { |l| l.include?("`reference_url`") && l.include?("Reference link") },
           "reference_url is not tied to the Reference link"
    assert_includes @prompt, "mailto"
  end
end
