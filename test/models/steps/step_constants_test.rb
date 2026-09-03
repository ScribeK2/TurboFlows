require "test_helper"

# The schema generator reads these constants, and the builder's own selects read
# them too. A value list written in a view is a value list the generator cannot
# see — which is how the import guide came to document a `date` form field the UI
# has never offered.
class StepConstantsTest < ActiveSupport::TestCase
  test "question answer types are declared as a constant" do
    assert_equal %w[text yes_no multiple_choice dropdown date number],
                 Steps::Question::VALID_ANSWER_TYPES
  end

  test "form field types are declared as a constant" do
    assert_equal %w[text textarea number email phone select checkbox],
                 Steps::Form::VALID_FIELD_TYPES
  end

  test "the question editor reads the constant rather than a literal list" do
    source = Rails.root.join("app/views/steps/fields/_question.html.erb").read

    assert_includes source, "Steps::Question::VALID_ANSWER_TYPES"
    assert_not_includes source, "{ value: 'yes_no'"
  end
end
