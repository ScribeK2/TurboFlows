# Unified service for condition validation and evaluation
# Used by both Workflow (validation) and Scenario (execution)
#
# Supported condition formats:
#   - variable == 'value'    (string equality, case-insensitive)
#   - variable != 'value'    (string inequality)
#   - variable > 10          (numeric greater than)
#   - variable >= 10         (numeric greater than or equal)
#   - variable < 10          (numeric less than)
#   - variable <= 10         (numeric less than or equal)
#
class ConditionEvaluator
  # A string value's content: whatever the delimiter allows, or a backslash
  # followed by any one character (the escape). Shared by VALID_PATTERNS (which
  # only needs to know a value is well-formed) and STRING_COMPARISON (which
  # captures it to unescape).
  STRING_VALUE = /'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/

  VALID_PATTERNS = [
    /^\w+\s*==\s*(?:#{STRING_VALUE.source})/, # variable == 'value' (escapes allowed)
    /^\w+\s*!=\s*(?:#{STRING_VALUE.source})/, # variable != 'value' (escapes allowed)
    /^\w+\s*>\s*\d+/,              # variable > 10
    /^\w+\s*<\s*\d+/,              # variable < 10
    /^\w+\s*>=\s*\d+/,             # variable >= 10
    /^\w+\s*<=\s*\d+/ # variable <= 10
  ].freeze

  OPERATORS = %w[>= <= != == > <].freeze

  # One string comparison, whole: a name, == or !=, and a value delimited by ' or
  # by " - the same one at both ends - in which a backslash escapes the next
  # character. The value groups are mutually exclusive.
  STRING_COMPARISON = /\A\s*(\w+)\s*(==|!=)\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")/
  WHOLE_STRING_COMPARISON = /#{STRING_COMPARISON.source}\s*\z/

  attr_reader :condition

  def initialize(condition)
    @condition = condition.to_s.strip
  end

  # Check if condition syntax is valid
  def valid?
    return false if condition.blank?

    VALID_PATTERNS.any? { |pattern| pattern.match?(condition) }
  end

  # Evaluate condition against a results hash
  # Returns true/false based on condition evaluation
  def evaluate(results)
    return false if condition.blank? || !results.is_a?(Hash)

    if (tokens = string_comparison)
      variable, operator, value = tokens
      return compare_values(operator, lookup_value(variable, results), value)
    end

    if condition.include?('==') && condition.exclude?('!=')
      evaluate_equality(results)
    elsif condition.include?('!=')
      evaluate_inequality(results)
    elsif condition.match?(/^\w+\s*>=\s*\d+/)
      evaluate_numeric(:>=, results)
    elsif condition.match?(/^\w+\s*<=\s*\d+/)
      evaluate_numeric(:<=, results)
    elsif condition.match?(/^\w+\s*>\s*\d+/)
      evaluate_numeric(:>, results)
    elsif condition.match?(/^\w+\s*<\s*\d+/)
      evaluate_numeric(:<, results)
    else
      false
    end
  end

  # Parse condition into components for UI display
  # Returns { variable: 'name', operator: '==', value: 'test' } or nil
  def parse
    return nil if condition.blank?

    if (tokens = string_comparison)
      variable, operator, value = tokens
      return {
        variable: variable,
        operator: operator,
        value: value,
        is_numeric: value.match?(/^\d+$/)
      }
    end

    # Try each operator in order (longer operators first to avoid partial matches)
    OPERATORS.each do |op|
      next unless condition.include?(op)

      parts = condition.split(op, 2).map(&:strip)
      next if parts.length != 2

      variable = parts[0].gsub(/['"]/, '').strip
      value = parts[1].gsub(/['"]/, '').strip

      return {
        variable: variable,
        operator: op,
        value: value,
        is_numeric: value.match?(/^\d+$/)
      }
    end

    nil
  end

  # Class method for quick validation
  def self.valid?(condition)
    new(condition).valid?
  end

  # VALID_PATTERNS anchor at the start but not the end, so #valid? is true for
  # anything that merely BEGINS with a comparison — "tier == 'gold' && region ==
  # 'EU'" passes it, and #evaluate then reads only as much as it understands.
  # These are the same six forms anchored at both ends, derived rather than
  # restated so the two cannot drift.
  COMPLETE_PATTERNS = VALID_PATTERNS.map { |pattern| Regexp.new("#{pattern.source}\\s*\\z") }.freeze

  # True when the WHOLE string is one supported comparison and nothing else.
  # The question two importers ask: the strict one to refuse a compound
  # condition, the Markdown one to tell a condition from a label.
  def self.complete?(condition)
    text = condition.to_s.strip
    COMPLETE_PATTERNS.any? { |pattern| pattern.match?(text) }
  end

  # Class method for quick evaluation
  def self.evaluate(condition, results)
    new(condition).evaluate(results)
  end

  private

  def evaluate_equality(results)
    evaluate_comparison('==', results)
  end

  def evaluate_inequality(results)
    evaluate_comparison('!=', results)
  end

  # Shared logic for == and != comparisons.
  # For ==, nil means false; for !=, nil means true.
  def evaluate_comparison(operator, results)
    parts = condition.split(operator, 2).map(&:strip)
    key = parts[0].gsub(/['"]/, '').strip
    expected_value = parts[1].gsub(/['"]/, '').strip

    compare_values(operator, lookup_value(key, results), expected_value)
  end

  # The == / != comparison itself, shared by the legacy quote-stripping reader
  # above and the tokenizer below. For ==, a nil result means false; for !=, it
  # means true. Otherwise a case-insensitive string comparison.
  def compare_values(operator, result_value, expected_value)
    return operator == '!=' if result_value.nil?

    values_equal = result_value.to_s.downcase == expected_value.to_s.downcase
    operator == '==' ? values_equal : !values_equal
  end

  # [variable, operator, unescaped, stripped value] when the WHOLE condition is
  # one well-formed string comparison; nil otherwise, and the caller falls back
  # to the reader this class has always had. That fallback is deliberate: it
  # strips every quote character and tolerates mismatched delimiters and
  # unquoted values, and live workflows route on it. It could never match a
  # value that contains a quote - which is the one thing this tokenizer adds.
  # The value is stripped here, once, so both #evaluate and #parse agree on it
  # the same way the legacy reader's two halves always have.
  def string_comparison
    match = WHOLE_STRING_COMPARISON.match(condition)
    return unless match

    value = (match[3] || match[4]).gsub(/\\(.)/m) { Regexp.last_match(1) }
    [match[1], match[2], value.strip]
  end

  def evaluate_numeric(operator, results)
    # Match pattern like: variable >= 10
    match = condition.match(/^(\w+)\s*#{Regexp.escape(operator.to_s)}\s*(\d+)/)
    return false unless match

    key = match[1].strip
    threshold = match[2].to_i
    value = (lookup_value(key, results) || 0).to_i

    case operator
    when :>  then value > threshold
    when :>= then value >= threshold
    when :<  then value < threshold
    when :<= then value <= threshold
    else false
    end
  end

  def lookup_value(key, results)
    # 1. Direct key lookup
    value = results[key]
    return value if value.present?

    # 2. If key is "answer", check last value (for legacy conditions)
    if key.downcase == 'answer'
      value = results.values.last
      return value if value.present?
    end

    # 3. Case-insensitive key lookup
    results.find { |k, v| k.to_s.downcase == key.to_s.downcase }&.last
  end
end
