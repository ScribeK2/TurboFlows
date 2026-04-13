module Steps
  class Resolve < Step
    has_rich_text :description

    # "escalated" = workflow ended via escalation (outcome recording).
    # Use Escalate step type for the act of escalating; use Resolve with
    # resolution_type "escalated" to record that the workflow ended because
    # of an escalation.
    VALID_RESOLUTION_TYPES = %w[success failure cancelled escalated transfer ticket manager_escalation].freeze

    DEFAULT_DESCRIPTIONS = {
      "success" => "The customer's issue has been fully resolved. Confirm with the customer that they're satisfied before ending the interaction.",
      "failure" => "The issue could not be resolved at this time. Apologize for the inconvenience and explain any next steps the customer can expect.",
      "cancelled" => "The customer has requested to cancel or withdraw their request. Confirm the cancellation and note any relevant details.",
      "escalated" => "This issue has been escalated to a specialized team. Let the customer know what to expect and provide any reference numbers.",
      "transfer" => "The customer is being transferred to another department or agent. Brief the receiving party and let the customer know who they'll be speaking with.",
      "ticket" => "A support ticket has been created for follow-up. Provide the customer with the ticket number and expected response time.",
      "manager_escalation" => "This issue requires manager attention. Document the situation clearly and notify the appropriate manager."
    }.freeze

    validates :resolution_type, inclusion: { in: VALID_RESOLUTION_TYPES }, allow_blank: true

    def resolution_description
      if description.present?
        description
      else
        self.class.default_description_for(resolution_type)
      end
    end

    def self.default_description_for(type)
      DEFAULT_DESCRIPTIONS[type.to_s]
    end

    def outcome_summary
      resolution_type&.titleize.to_s
    end

    def terminal?
      true
    end
  end
end
