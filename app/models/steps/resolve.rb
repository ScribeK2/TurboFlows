module Steps
  class Resolve < Step
    VALID_RESOLUTION_TYPES = %w[success failure cancelled escalated transferred other transfer ticket manager_escalation].freeze

    validates :resolution_type, inclusion: { in: VALID_RESOLUTION_TYPES }, allow_blank: true

    def outcome_summary
      parts = []
      parts << resolution_type&.titleize if resolution_type.present?
      parts << "(#{resolution_code})" if resolution_code.present?
      parts.join(" ")
    end

    def terminal?
      true
    end
  end
end
