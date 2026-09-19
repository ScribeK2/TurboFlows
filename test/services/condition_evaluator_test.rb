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

  test "complete? accepts an escaped quote, and still refuses an unescaped one" do
    assert ConditionEvaluator.complete?("light == 'Don\\'t know'")
    assert ConditionEvaluator.complete?(%(light == "Don't know"))
    assert_not ConditionEvaluator.complete?("light == 'Don't know'")
  end

  # Correction (2026-09-19): mismatched delimiters (`'yes"`) were ALWAYS
  # accepted by complete?/valid? before this branch - the base pattern
  # `['"][^'"]*['"]` never required the same quote at both ends, only "no
  # quote characters inside". An earlier draft of this grammar tightened
  # LEGACY_STRING_VALUE to require matched delimiters, which silently
  # NARROWED complete?/valid? below what they accepted before: a stored
  # mismatched-delimiter condition (reachable through the lenient import
  # path) would export to a file the strict importer refused, and the
  # Markdown parser would misread it as a label instead of a condition.
  # complete?/valid? must stay a SUPERSET of what they accepted before
  # 2026-09-19, so LEGACY_STRING_VALUE is the pre-existing pattern verbatim -
  # mismatched delimiters included. #evaluate/#parse were never affected
  # either way: the legacy fallback has always read this shape the same way,
  # both before and after. Verified against 2efe44db with a corpus
  # comparison script.
  test "complete? still accepts mismatched delimiters, exactly as it did before this branch" do
    assert ConditionEvaluator.complete?(%(light == 'yes"))
    assert ConditionEvaluator.complete?(%(light == "yes'))
    assert ConditionEvaluator.valid?(%(light == 'yes"))
  end

  # A value ending in a bare backslash - what Step::Doors#condition_for wrote
  # for such a value before writers escaped backslashes, and what the legacy
  # path has always read correctly for #evaluate/#parse - has no valid close
  # under STRING_VALUE's escape rule (the trailing backslash consumes the
  # closing quote as an "escaped" character), so it depends on the same
  # LEGACY_STRING_VALUE alternative as the mismatched-delimiters case above.
  test "complete? accepts a value ending in a bare backslash, for both delimiters" do
    backslash = "\\"
    single = "path == 'C:#{backslash}'" # ONE literal backslash, single-quoted
    double = %(path == "C:#{backslash}") # ONE literal backslash, double-quoted
    answer = "C:#{backslash}"

    assert_equal 1, single.count(backslash), "precondition: exactly one backslash"
    assert_equal 1, double.count(backslash), "precondition: exactly one backslash"

    assert ConditionEvaluator.complete?(single)
    assert ConditionEvaluator.complete?(double)
    assert ConditionEvaluator.valid?(single)

    assert ConditionEvaluator.evaluate(single, { "path" => answer })
    parsed = ConditionEvaluator.new(single).parse
    assert_equal answer, parsed[:value]
    assert_equal answer, parsed[:literal_value]
  end

  # An unescaped inner quote and a compound condition were refused by
  # complete? at 2efe44db too (verified in the same corpus comparison
  # script), so keeping them refused here is not a narrowing - unlike
  # mismatched delimiters above, which base always accepted.
  test "complete? still refuses an unescaped inner quote and a compound condition" do
    assert_not ConditionEvaluator.complete?("light == 'Don't know'"), "unescaped inner quote"
    assert_not ConditionEvaluator.complete?("a == 'x' && b == 'y'"), "a compound condition"
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
    # The panel has never escaped a backslash (that starts with this branch, going
    # forward only): a value ending in one, like a Windows path, was written
    # bare. The trailing backslash swallows the closing quote as an "escaped"
    # character, so the tokenizer can't close the string and declines - the
    # legacy path reads it exactly as it always has.
    assert ConditionEvaluator.evaluate("path == 'C:\\'", { "path" => "C:\\" }), "a value ending in a bare backslash"
  end

  # --- two readings of a value (pre-review ruling, 2026-09-19) ---
  #
  # A note on Ruby string-literal escaping, since it is easy to lose count
  # here: `"x == 'Don\\'t'"` in Ruby SOURCE is the condition TEXT
  # `x == 'Don\'t'` - one backslash, not two - because `\\` in a Ruby
  # double-quoted literal is itself an escape for a single backslash
  # character. Every fixture below is built with `"\\" * n` (one call per
  # count) rather than typed out, and checked with `.count("\\")`, so the
  # number of literal backslashes in each condition/answer is never in doubt.
  #
  # A condition written before 2026-09-19 escaped a quote but never a
  # backslash (Step::Doors#condition_for and the panel's writer both only
  # ever did), so a STORED value with a bare "\" - a Windows path, a
  # DOMAIN\user - is a literal backslash, not the start of an escape. The
  # unescaped-only tokenizer above would silently stop matching such a value.
  # `==`/`!=` now compare against EITHER reading: unescaped, or literal (the
  # text between the delimiters exactly as written).

  test "a stored value with a bare backslash still matches (both readings)" do
    backslash = "\\"
    condition = "path == 'C:#{backslash}temp'" # ONE literal backslash in the condition text
    answer = "C:#{backslash}temp"

    assert_equal 1, condition.count(backslash), "precondition: exactly one backslash in the condition"
    assert ConditionEvaluator.evaluate(condition, { "path" => answer })
    assert_not ConditionEvaluator.evaluate(condition.sub("==", "!="), { "path" => answer })
    assert ConditionEvaluator.evaluate(condition.sub("==", "!="), { "path" => "something else" })
  end

  test "an escaped value and its bare form both match the same real answer" do
    backslash = "\\"
    # The real value is a UNC path: two leading backslashes, one separator -
    # three literal backslashes total.
    real_value = "#{backslash * 2}server#{backslash}docs"
    bare_condition = "share == '#{real_value}'" # written exactly as typed, unescaped
    escaped_condition = "share == '#{backslash * 4}server#{backslash * 2}docs'" # every backslash doubled

    assert_equal 3, real_value.count(backslash), "precondition: three backslashes in the real value"
    assert ConditionEvaluator.evaluate(bare_condition, { "share" => real_value }), "the literal reading matches"
    assert ConditionEvaluator.evaluate(escaped_condition, { "share" => real_value }), "the unescaped reading matches"
  end

  test "parse returns both the unescaped and the literal reading of the value" do
    backslash = "\\"
    parsed = ConditionEvaluator.new("path == 'C:#{backslash * 2}temp'").parse # escaped: 2 backslashes written for 1 real one

    assert_equal "C:#{backslash}temp", parsed[:value]
    assert_equal "C:#{backslash * 2}temp", parsed[:literal_value]

    # No backslash in the value: the two readings are the same string.
    plain = ConditionEvaluator.new("light == 'yes'").parse
    assert_equal plain[:value], plain[:literal_value]
  end

  # Concern raised in review, accepted as a second deliberate exception:
  # before 2026-09-19, `light == 'a!=b'` was read by evaluate_inequality (the
  # condition CONTAINS '!=', so the equality branch was skipped), which
  # splits the whole condition on the first '!=' - landing inside the quoted
  # value, not on the real operator. That produced a nonsense key and a nil
  # lookup, and the != branch's nil rule returns true unconditionally: this
  # condition matched EVERY answer, not just the one it named. That was never
  # something a workflow could rely on being "no". The tokenizer parses the
  # whole condition as one well-formed == comparison instead, so it now
  # compares for real.
  test "a value containing '!=' under == no longer always matches" do
    assert ConditionEvaluator.evaluate("light == 'a!=b'", { "light" => "a!=b" })
    assert_not ConditionEvaluator.evaluate("light == 'a!=b'", { "light" => "something else" })
  end

  # The tokenizer's two patterns are how this class reads a condition, not
  # something another reader may match against: every other reader goes through
  # #parse, which is what keeps the value's two readings in one place.
  test "the tokenizer's patterns are not part of the public surface" do
    assert_raises(NameError) { ConditionEvaluator::STRING_COMPARISON }
    assert_raises(NameError) { ConditionEvaluator::WHOLE_STRING_COMPARISON }
  end
end
