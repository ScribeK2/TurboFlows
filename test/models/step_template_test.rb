require "test_helper"

class StepTemplateTest < ActiveSupport::TestCase
  test "for_type returns templates hash for valid type" do
    result = StepTemplate.for_type(:question)
    assert_instance_of Hash, result
    assert result.key?("simple_yes_no")
    assert result.key?("text_input")
    assert result.key?("multiple_choice")
  end

  test "for_type returns empty hash for unknown type" do
    result = StepTemplate.for_type(:nonexistent)
    assert_equal({}, result)
  end

  test "all_for_type returns array with key included" do
    result = StepTemplate.all_for_type(:question)
    assert_instance_of Array, result
    assert_operator result.length, :>=, 3
    assert(result.all? { |t| t[:key].present? })
    assert(result.all? { |t| t[:name].present? })
    assert(result.all? { |t| t[:type] == "question" })
  end

  test "find returns template with key for valid type and key" do
    result = StepTemplate.find(:question, :simple_yes_no)
    assert_not_nil result
    assert_equal "simple_yes_no", result[:key]
    assert_equal "Simple Yes/No Question", result[:name]
    assert_equal "question", result[:type]
  end

  test "find returns nil for invalid type or key" do
    assert_nil StepTemplate.find(:question, :nonexistent)
    assert_nil StepTemplate.find(:nonexistent, :simple_yes_no)
  end
end
