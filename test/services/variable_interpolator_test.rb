require "test_helper"

class VariableInterpolatorTest < ActiveSupport::TestCase
  test "interpolate replaces simple variables" do
    text = "Hello {{name}}, welcome!"
    variables = { "name" => "John" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Hello John, welcome!", result
  end

  test "interpolate handles multiple variables" do
    text = "Hello {{first_name}} {{last_name}}, your status is {{status}}"
    variables = { "first_name" => "John", "last_name" => "Doe", "status" => "active" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Hello John Doe, your status is active", result
  end

  test "interpolate handles symbol keys in variables hash" do
    text = "Status: {{status}}"
    variables = { status: "active" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Status: active", result
  end

  test "interpolate leaves missing variables as-is" do
    text = "Hello {{name}}, your {{missing}} variable"
    variables = { "name" => "John" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Hello John, your {{missing}} variable", result
  end

  test "interpolate handles nil values" do
    text = "Status: {{status}}"
    variables = { "status" => nil }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Status: ", result
  end

  test "interpolate handles empty text" do
    assert_equal "", VariableInterpolator.interpolate("", {})
    assert_equal "", VariableInterpolator.interpolate(nil, {})
  end

  test "interpolate handles empty variables hash" do
    text = "Hello {{name}}"
    result = VariableInterpolator.interpolate(text, {})

    assert_equal "Hello {{name}}", result
  end

  test "interpolate handles non-string values" do
    text = "Count: {{count}}, Active: {{active}}"
    variables = { "count" => 42, "active" => true }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Count: 42, Active: true", result
  end

  test "interpolate handles same variable multiple times" do
    text = "{{name}} says hello, {{name}}!"
    variables = { "name" => "Alice" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Alice says hello, Alice!", result
  end

  test "extract_variables finds all variables in text" do
    text = "Hello {{name}}, your {{status}} is {{status}}"
    variables = VariableInterpolator.extract_variables(text)

    assert_equal %w[name status], variables.sort
  end

  test "extract_variables returns empty array for text without variables" do
    assert_empty VariableInterpolator.extract_variables("No variables here")
    assert_empty VariableInterpolator.extract_variables("")
    assert_empty VariableInterpolator.extract_variables(nil)
  end

  test "contains_variables? returns true when variables present" do
    assert VariableInterpolator.contains_variables?("Hello {{name}}")
    assert VariableInterpolator.contains_variables?("{{var1}} and {{var2}}")
  end

  test "contains_variables? returns false when no variables" do
    assert_not VariableInterpolator.contains_variables?("No variables")
    assert_not VariableInterpolator.contains_variables?("")
    assert_not VariableInterpolator.contains_variables?(nil)
  end

  # Edge cases for 1.3.3
  test "interpolate handles nested braces that are not variables" do
    text = "This has {{not a var}} and {{this_is_a_var}}"
    variables = { "this_is_a_var" => "replaced" }
    result = VariableInterpolator.interpolate(text, variables)
    # Should only replace valid variable patterns
    assert_equal "This has {{not a var}} and replaced", result
  end

  test "interpolate handles variables at start and end of string" do
    text = "{{greeting}} world {{punctuation}}"
    variables = { "greeting" => "Hello", "punctuation" => "!" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Hello world !", result
  end

  test "interpolate handles consecutive variables" do
    text = "{{first}}{{second}}{{third}}"
    variables = { "first" => "1", "second" => "2", "third" => "3" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "123", result
  end

  test "interpolate handles special characters in variable values" do
    text = "Value: {{value}}"
    variables = { "value" => "<script>alert('xss')</script>" }
    result = VariableInterpolator.interpolate(text, variables)
    # Should handle special chars (though escaping should happen at view level)
    assert_equal "Value: <script>alert('xss')</script>", result
  end

  test "interpolate handles very long variable names" do
    long_var = "a" * 100
    text = "Test {{#{long_var}}}"
    variables = { long_var => "replaced" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Test replaced", result
  end

  test "interpolate handles numeric variable names" do
    text = "Count {{123}}"
    variables = { "123" => "works" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Count works", result
  end

  test "interpolate handles underscore and alphanumeric variable names" do
    text = "Var1: {{var_name}} Var2: {{varName123}}"
    variables = { "var_name" => "test1", "varName123" => "test2" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Var1: test1 Var2: test2", result
  end

  test "extract_variables handles complex text with multiple variables" do
    text = "{{start}} middle text {{middle}} and more {{end}}"
    variables = VariableInterpolator.extract_variables(text)

    assert_equal %w[end middle start], variables.sort
  end

  test "interpolate preserves whitespace around variables" do
    text = "Before {{var}} after"
    variables = { "var" => "value" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "Before value after", result
  end

  test "interpolate handles variables with same prefix" do
    text = "{{user}} and {{user_name}} and {{user_email}}"
    variables = { "user" => "John", "user_name" => "John Doe", "user_email" => "john@example.com" }
    result = VariableInterpolator.interpolate(text, variables)

    assert_equal "John and John Doe and john@example.com", result
  end

  test "normalize_variables converts symbol keys to strings" do
    input = { foo: "bar", "baz" => "qux" }
    result = VariableInterpolator.normalize_variables(input)
    assert_equal({ "foo" => "bar", "baz" => "qux" }, result)
  end

  test "normalize_variables returns empty hash for non-hash input" do
    assert_equal({}, VariableInterpolator.normalize_variables(nil))
    assert_equal({}, VariableInterpolator.normalize_variables("string"))
  end
  # Someone who types {{ name }} means an interpolation. The pattern allowed no
  # inner spaces, so the agent on a live call read the braces — while the strict
  # importer, whose own copy of the pattern DID allow them, validated the same
  # text as a working interpolation. Two readers, two answers.
  test "inner spaces are an interpolation, not literal text" do
    assert_equal "Hello John!", VariableInterpolator.interpolate("Hello {{ name }}!", { "name" => "John" })
    assert_equal "Hello John!", VariableInterpolator.interpolate("Hello {{name }}!", { "name" => "John" })
    assert_equal ["name"], VariableInterpolator.extract_variables("Hello {{ name }}!")
  end

  test "an unknown spaced variable is still left exactly as written" do
    assert_equal "Hello {{ nobody }}!", VariableInterpolator.interpolate("Hello {{ nobody }}!", { "name" => "John" })
  end

  # Every reader of "what is an interpolation" must be this constant. The
  # importer and StepHelper#highlight_variables each carried a hand-written
  # copy, and the copies had already drifted apart.
  test "nothing else in the app spells its own interpolation pattern" do
    offenders = Rails.root.glob("app/**/*.{rb,erb,js}").reject { |f| f.basename.to_s == "variable_interpolator.rb" }
                     .select { |f| f.read.include?("\\{\\{") }

    assert_empty offenders.map { |f| f.relative_path_from(Rails.root).to_s },
                 "reference VariableInterpolator::VARIABLE_PATTERN instead"
  end
end
