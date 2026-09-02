module Steps
  class Question < Step
    # The answer types the builder offers and the import schema publishes.
    # Order is the order the editor renders them in.
    VALID_ANSWER_TYPES = %w[text yes_no multiple_choice dropdown date number].freeze

    validates :question, presence: true, on: :publish

    before_validation :generate_variable_name, if: -> { variable_name.blank? && title.present? }

    def outcome_summary
      parts = []
      parts << answer_type&.titleize if answer_type.present?
      parts << question.truncate(80) if question.present?
      parts << "{{#{variable_name}}}" if variable_name.present?
      parts.join(": ")
    end

    private

    def generate_variable_name
      self.variable_name = title
                           .to_s.strip
                           .gsub(/[?!.,;:'"(){}\[\]]/, "")
                           .parameterize(separator: "_")
                           .tr("-", "_").squeeze("_")
                           .gsub(/^_|_$/, "")
                           .first(30)
                           .gsub(/_$/, "")
    end
  end
end
