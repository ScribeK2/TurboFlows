module Steps
  class Question < Step
    # The answer types the builder offers and the import schema publishes.
    # Order is the order the editor renders them in.
    VALID_ANSWER_TYPES = %w[text yes_no multiple_choice dropdown date number].freeze

    before_validation :generate_variable_name, if: -> { variable_name.blank? && title.present? }
    before_validation :default_option_values_to_labels

    def outcome_summary
      parts = []
      parts << answer_type&.titleize if answer_type.present?
      parts << question.truncate(80) if question.present?
      parts << "{{#{variable_name}}}" if variable_name.present?
      parts.join(": ")
    end

    # Public so GrowStep can build a name and make it unique before the save;
    # the callback below still covers every other writer.
    def self.variable_name_from(title)
      title.to_s.strip
           .gsub(/[?!.,;:'"(){}\[\]]/, "")
           .parameterize(separator: "_")
           .tr("-", "_").squeeze("_")
           .gsub(/^_|_$/, "")
           .first(30)
           .gsub(/_$/, "")
    end

    private

    # A Transition matches on an option's `value`, never on its `label`, but the
    # panel offers the two as bare fields side by side with nothing saying which
    # is which. Filling in only the label therefore built a branch that could
    # never fire, and nothing reported it. Falling back to the label makes the
    # split opt-in: spell a value out only when it must differ from what the
    # agent reads. Runs on every save, so blanking a value re-derives it rather
    # than leaving the option unmatchable.
    #
    # An option with no label has nothing to fall back to and is left alone —
    # WorkflowHealthCheck reports that one.
    def default_option_values_to_labels
      return unless options.is_a?(Array)

      self.options = options.map do |option|
        next option unless option.is_a?(Hash)

        label = option["label"] || option[:label]
        value = option["value"] || option[:value]
        next option if value.to_s.strip.present? || label.to_s.strip.blank?

        option.merge(option.key?(:label) ? { value: label } : { "value" => label })
      end
    end

    def generate_variable_name
      self.variable_name = self.class.variable_name_from(title)
    end
  end
end
