require "test_helper"

class ConditionEvaluatorTest < ActiveSupport::TestCase
  # ==========================================================================
  # Validation Tests
  # ==========================================================================

  test "validates string equality condition" do
    assert ConditionEvaluator.valid?("status == 'active'")
    assert ConditionEvaluator.valid?('status == "active"')
    assert ConditionEvaluator.valid?("var == 'yes'")
  end

  test "validates string inequality condition" do
    assert ConditionEvaluator.valid?("status != 'closed'")
    assert ConditionEvaluator.valid?('status != "pending"')
  end

  test "validates numeric comparison conditions" do
    assert ConditionEvaluator.valid?("count > 10")
    assert ConditionEvaluator.valid?("count >= 10")
    assert ConditionEvaluator.valid?("count < 100")
    assert ConditionEvaluator.valid?("count <= 100")
  end

  test "rejects invalid condition formats" do
    assert_not ConditionEvaluator.valid?("")
    assert_not ConditionEvaluator.valid?(nil)
    assert_not ConditionEvaluator.valid?("x === 'yes'") # triple equals
    assert_not ConditionEvaluator.valid?("x = 'yes'") # single equals
    assert_not ConditionEvaluator.valid?("invalid")
  end

  # ==========================================================================
  # String Equality Evaluation Tests
  # ==========================================================================

  test "evaluates string equality correctly" do
    results = { "status" => "active" }

    assert ConditionEvaluator.evaluate("status == 'active'", results)
    assert_not ConditionEvaluator.evaluate("status == 'inactive'", results)
  end

  test "string equality is case-insensitive" do
    results = { "answer" => "YES" }

    assert ConditionEvaluator.evaluate("answer == 'yes'", results)
    assert ConditionEvaluator.evaluate("answer == 'YES'", results)
    assert ConditionEvaluator.evaluate("answer == 'Yes'", results)
  end

  test "evaluates string inequality correctly" do
    results = { "status" => "open" }

    assert ConditionEvaluator.evaluate("status != 'closed'", results)
    assert_not ConditionEvaluator.evaluate("status != 'open'", results)
  end

  test "missing variable returns false for equality" do
    results = {}

    assert_not ConditionEvaluator.evaluate("missing == 'value'", results)
  end

  test "missing variable returns true for inequality" do
    results = {}

    assert ConditionEvaluator.evaluate("missing != 'value'", results)
  end

  # ==========================================================================
  # Numeric Comparison Tests
  # ==========================================================================

  test "evaluates greater than correctly" do
    results = { "count" => "15" }

    assert ConditionEvaluator.evaluate("count > 10", results)
    assert_not ConditionEvaluator.evaluate("count > 15", results)
    assert_not ConditionEvaluator.evaluate("count > 20", results)
  end

  test "evaluates greater than or equal correctly" do
    results = { "count" => "10" }

    assert ConditionEvaluator.evaluate("count >= 10", results)
    assert ConditionEvaluator.evaluate("count >= 5", results)
    assert_not ConditionEvaluator.evaluate("count >= 15", results)
  end

  test "evaluates less than correctly" do
    results = { "count" => "5" }

    assert ConditionEvaluator.evaluate("count < 10", results)
    assert_not ConditionEvaluator.evaluate("count < 5", results)
    assert_not ConditionEvaluator.evaluate("count < 3", results)
  end

  test "evaluates less than or equal correctly" do
    results = { "count" => "10" }

    assert ConditionEvaluator.evaluate("count <= 10", results)
    assert ConditionEvaluator.evaluate("count <= 15", results)
    assert_not ConditionEvaluator.evaluate("count <= 5", results)
  end

  test "missing numeric variable defaults to 0" do
    results = {}

    assert_not ConditionEvaluator.evaluate("count > 0", results)
    assert ConditionEvaluator.evaluate("count >= 0", results)
    assert ConditionEvaluator.evaluate("count < 10", results)
  end

  # ==========================================================================
  # Variable Lookup Tests
  # ==========================================================================

  test "case-insensitive variable lookup" do
    results = { "CustomerName" => "John" }

    assert ConditionEvaluator.evaluate("customername == 'John'", results)
    assert ConditionEvaluator.evaluate("CUSTOMERNAME == 'John'", results)
  end

  test "answer keyword uses last value for legacy support" do
    results = { "first" => "value1", "second" => "value2" }

    assert ConditionEvaluator.evaluate("answer == 'value2'", results)
  end

  # ==========================================================================
  # Parse Tests
  # ==========================================================================

  test "parses string equality condition" do
    evaluator = ConditionEvaluator.new("status == 'active'")
    parsed = evaluator.parse

    assert_equal "status", parsed[:variable]
    assert_equal "==", parsed[:operator]
    assert_equal "active", parsed[:value]
    assert_not parsed[:is_numeric]
  end

  test "parses numeric condition" do
    evaluator = ConditionEvaluator.new("count >= 100")
    parsed = evaluator.parse

    assert_equal "count", parsed[:variable]
    assert_equal ">=", parsed[:operator]
    assert_equal "100", parsed[:value]
    assert parsed[:is_numeric]
  end

  test "parse returns nil for invalid condition" do
    evaluator = ConditionEvaluator.new("invalid")

    assert_nil evaluator.parse
  end

  # ==========================================================================
  # Edge Cases
  # ==========================================================================

  test "handles whitespace in conditions" do
    results = { "status" => "active" }

    assert ConditionEvaluator.evaluate("  status  ==  'active'  ", results)
    assert ConditionEvaluator.evaluate("count >= 10", { "count" => "15" })
  end

  test "handles empty results hash" do
    assert_not ConditionEvaluator.evaluate("status == 'active'", {})
  end

  test "handles nil results" do
    assert_not ConditionEvaluator.evaluate("status == 'active'", nil)
  end

  # ==========================================================================
  # Instance API Tests (required by audit)
  # ==========================================================================

  test "instance evaluate works" do
    evaluator = ConditionEvaluator.new("age > 21")
    assert evaluator.evaluate({ "age" => "30" })
    assert_not evaluator.evaluate({ "age" => "18" })
  end

  test "blank condition returns false on evaluate" do
    assert_not ConditionEvaluator.evaluate("", { "status" => "active" })
  end
  # valid? is true for anything that BEGINS with a comparison. complete? asks for
  # the whole string, which is what both importers actually need to know.
  test "complete? wants the whole string to be one comparison" do
    assert ConditionEvaluator.complete?("tier == 'gold'")
    assert ConditionEvaluator.complete?("  wait > 3  ")

    assert ConditionEvaluator.valid?("tier == 'gold' && region == 'EU'"), "precondition: valid? accepts a prefix"
    assert_not ConditionEvaluator.complete?("tier == 'gold' && region == 'EU'")
    assert_not ConditionEvaluator.complete?("wait > 3 days then call")
    assert_not ConditionEvaluator.complete?("Billing")
    assert_not ConditionEvaluator.complete?(nil)
  end

  # --- string values that contain a quote (2026-09-19) ---

  test "an escaped apostrophe in the value matches the answer that contains one" do
    assert ConditionEvaluator.evaluate("light == 'Don\\'t know'", { "light" => "Don't know" })
    assert_not ConditionEvaluator.evaluate("light == 'Don\\'t know'", { "light" => "Dont know" })
  end

  test "a double-quoted value may contain an apostrophe, and the reverse" do
    assert ConditionEvaluator.evaluate(%(light == "Don't know"), { "light" => "don't know" })
    assert ConditionEvaluator.evaluate(%(light == 'Say "OK"'), { "light" => 'Say "OK"' })
  end

  test "an escaped backslash is one backslash" do
    assert ConditionEvaluator.evaluate("path == 'C:\\\\temp'", { "path" => "C:\\temp" })
  end

  test "inequality reads the same grammar" do
    assert ConditionEvaluator.evaluate("light != 'Don\\'t know'", { "light" => "Yes" })
    assert_not ConditionEvaluator.evaluate("light != 'Don\\'t know'", { "light" => "Don't know" })
  end

  test "parse returns the unescaped value" do
    parsed = ConditionEvaluator.new("light == 'Don\\'t know'").parse
    assert_equal ["light", "==", "Don't know"], parsed.values_at(:variable, :operator, :value)
  end

  # parse has always stripped the expected value (as the old split-based reader
  # does), and Step::Doors relies on that: it compares parsed_value with no
  # strip of its own. The tokenizer must agree.
  test "parse strips a padded value the same as the legacy reader always did" do
    assert_equal "yes", ConditionEvaluator.new("light == ' yes '").parse[:value]
    assert ConditionEvaluator.new("count == ' 5 '").parse[:is_numeric]
  end

  test "complete? accepts an escaped quote and refuses mismatched delimiters" do
    assert ConditionEvaluator.complete?("light == 'Don\\'t know'")
    assert ConditionEvaluator.complete?(%(light == "Don't know"))
    assert_not ConditionEvaluator.complete?(%(light == 'yes"))
    assert_not ConditionEvaluator.complete?("light == 'Don't know'")
  end

  # A live workflow must not change routing because the parser got better: each
  # of these shapes takes the code path it took before, and answers as it did.
  test "legacy shapes evaluate exactly as they did" do
    assert ConditionEvaluator.evaluate(%(light == 'yes"), { "light" => "yes" }), "mismatched delimiters"
    assert ConditionEvaluator.evaluate("count == 5", { "count" => "5" }), "unquoted equality"
    assert ConditionEvaluator.evaluate("light=='YES'", { "light" => "yes" }), "no spaces, other case"
    assert ConditionEvaluator.evaluate("light == ' yes '", { "light" => "yes" }), "padded expected value"
    assert_not ConditionEvaluator.evaluate("tier == 'gold' && region == 'EU'", { "tier" => "gold", "region" => "EU" }),
               "a compound condition never matched on ==, and still does not"
    assert ConditionEvaluator.evaluate("answer == 'yes'", { "anything" => "yes" }), "legacy answer keyword"
    assert_not ConditionEvaluator.evaluate("x = 'yes'", { "x" => "yes" }), "single equals is not an operator"
    assert ConditionEvaluator.evaluate("my-var == 'x'", { "my-var" => "x" }), "a hyphenated name is not \\w+, so this falls to the legacy split"
    assert ConditionEvaluator.evaluate("x == ''", { "x" => "" }), "an empty quoted value matches an empty answer"
    # The panel has never escaped a backslash (that starts with this task, going
    # forward only): a value ending in one, like a Windows path, was written
    # bare. The trailing backslash swallows the closing quote as an "escaped"
    # character, so the tokenizer can't close the string and declines - the
    # legacy path reads it exactly as it always has.
    assert ConditionEvaluator.evaluate("path == 'C:\\'", { "path" => "C:\\" }), "a value ending in a bare backslash"
  end
end
