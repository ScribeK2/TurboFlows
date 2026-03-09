# Service class for interpolating variables in text strings
# Replaces {{variable_name}} patterns with values from a variables hash
#
# Usage:
#   VariableInterpolator.interpolate("Hello {{customer_name}}!", { "customer_name" => "John" })
#   # => "Hello John!"
#
# Handles missing variables by leaving the pattern as-is ({{variable_name}})
class VariableInterpolator
  # Pattern to match {{variable_name}} style variables
  # Matches: {{variable_name}}, {{var}}, {{some_long_variable_name}}
  # Does NOT match nested access (e.g., {{user.name}}) - keeping it simple for MVP
  VARIABLE_PATTERN = /\{\{(\w+)\}\}/

  # Interpolate variables in a text string
  #
  # @param text [String, nil] The text containing {{variable_name}} patterns
  # @param variables [Hash] Hash of variable names to values (keys can be strings or symbols)
  # @return [String] The text with variables replaced, or original text if nil/blank
  #
  # Examples:
  #   interpolate("Hello {{name}}!", { "name" => "John" }) => "Hello John!"
  #   interpolate("Status: {{status}}", { status: "active" }) => "Status: active"
  #   interpolate("{{missing}} variable", {}) => "{{missing}} variable" (missing vars left as-is)
  def self.interpolate(text, variables = {})
    return "" if text.nil?
    return text.to_s if text.blank?
    return text.to_s if variables.blank?

    # Normalize variables hash to use string keys for consistent lookup
    normalized_vars = normalize_variables(variables)

    # Replace all {{variable_name}} patterns
    text.to_s.gsub(VARIABLE_PATTERN) do |match|
      variable_name = ::Regexp.last_match(1) # Capture the variable name (without {{}})

      # Check if variable exists in hash (even if value is nil)
      if normalized_vars.key?(variable_name)
        # Variable exists - convert value to string (handles nil, boolean, numbers, etc.)
        normalized_vars[variable_name].to_s
      else
        # Variable not found - leave the pattern as-is
        match
      end
    end
  end

  # Interpolate variables within Action Text rich text content
  #
  # @param rich_text [ActionText::RichText, String, nil] The rich text or string to interpolate
  # @param variables [Hash] Hash of variable names to values
  # @return [String] The interpolated HTML string
  def self.interpolate_rich_text(rich_text, variables = {})
    return "" if rich_text.blank? || variables.blank?

    if rich_text.respond_to?(:body)
      html = rich_text.body.to_s
      interpolate(html, variables)
    else
      interpolate(rich_text.to_s, variables)
    end
  end

  # Extract all variable names from a text string
  #
  # @param text [String] The text containing {{variable_name}} patterns
  # @return [Array<String>] Array of unique variable names found in the text
  #
  # Example:
  #   extract_variables("Hello {{name}}, your status is {{status}}")
  #   # => ["name", "status"]
  def self.extract_variables(text)
    return [] if text.blank?

    text.to_s.scan(VARIABLE_PATTERN).flatten.uniq
  end

  # Check if a text string contains any variable patterns
  #
  # @param text [String] The text to check
  # @return [Boolean] True if text contains {{variable}} patterns
  def self.contains_variables?(text)
    return false if text.blank?

    text.to_s.match?(VARIABLE_PATTERN)
  end

  # Normalize variables hash to use string keys
  # Converts symbol keys to strings for consistent lookup
  #
  # @param variables [Hash] Hash with string or symbol keys
  # @return [Hash] Hash with string keys
  def self.normalize_variables(variables)
    return {} unless variables.is_a?(Hash)

    variables.transform_keys(&:to_s)
  end
end
