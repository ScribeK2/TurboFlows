module Steps
  class Form < Step
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
    # Returns an array of error strings (empty = valid).
    def validate_responses(response_data)
      errors = []

      fields.select { |f| f["required"] }.each do |field|
        value = response_data&.dig(field["name"])
        if value.blank?
          errors << "#{field['label'] || field['name']} is required"
        end
      end

      errors
    end

    def outcome_summary
      count = fields.size
      required = required_field_names.size
      "#{count} field#{'s' if count != 1} (#{required} required)"
    end
  end
end
