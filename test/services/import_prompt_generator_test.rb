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
end
