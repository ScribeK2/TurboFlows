module Steps
  class Form < Step
    # The field types the form builder offers and the import schema publishes.
    VALID_FIELD_TYPES = %w[text textarea number email phone select checkbox].freeze

    has_rich_text :instructions

    # Fields are stored in the `options` JSON column as an array of hashes:
    #   [{ "name" => "phone", "label" => "Phone", "field_type" => "text", "required" => true, "position" => 0 }]

    def step_type
      "form"
    end

    # Returns the field definitions (alias for options)
    def fields
      options || []
    end

    # Returns the names of all required fields
    def required_field_names
      fields.select { |f| f["required"] }.pluck("name")
    end

    # Look up a single field definition by name
    def field_by_name(name)
      fields.find { |f| f["name"] == name }
    end

    # Validate a hash of responses against the field definitions.
    #
    # Keyed by field name, so a refusal can be shown under the input it is
    # about. It used to return a flat array of sentences, which left a long form
    # rendering one block above the fields and the agent matching each message
    # back to an input by reading the label out of it. Escalate and Resolve have
    # exactly one field each and so never had the problem.
    #
    # Empty hash = valid.
    def validate_responses(response_data)
      fields.select { |f| f["required"] }.each_with_object({}) do |field, errors|
        next if response_data&.dig(field["name"]).present?

        errors[field["name"]] = ["#{field['label'] || field['name']} is required"]
      end
    end

    def outcome_summary
      count = fields.size
      required = required_field_names.size
      "#{count} field#{'s' if count != 1} (#{required} required)"
    end
  end
end
