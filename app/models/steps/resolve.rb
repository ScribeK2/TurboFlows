module Steps
  class Resolve < Step
    # "escalated" = workflow ended via escalation (outcome recording).
    # Use Escalate step type for the act of escalating; use Resolve with
    # resolution_type "escalated" to record that the workflow ended because
    # of an escalation.
    VALID_RESOLUTION_TYPES = %w[success failure cancelled escalated transfer ticket manager_escalation].freeze

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
