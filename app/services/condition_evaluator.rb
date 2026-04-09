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
  VALID_PATTERNS = [
    /^\w+\s*==\s*['"][^'"]*['"]/,  # variable == 'value'
    /^\w+\s*!=\s*['"][^'"]*['"]/,  # variable != 'value'
    /^\w+\s*>\s*\d+/,              # variable > 10
    /^\w+\s*<\s*\d+/,              # variable < 10
    /^\w+\s*>=\s*\d+/,             # variable >= 10
    /^\w+\s*<=\s*\d+/ # variable <= 10
  ].freeze

  OPERATORS = %w[>= <= != == > <].freeze

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

    result_value = lookup_value(key, results)
    return operator == '!=' if result_value.nil?

    # Case-insensitive comparison for strings
    values_equal = result_value.to_s.downcase == expected_value.to_s.downcase
    operator == '==' ? values_equal : !values_equal
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
