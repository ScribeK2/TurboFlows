class Steps::Resolve < Step
  VALID_RESOLUTION_TYPES = %w[success failure cancelled escalated transferred other transfer ticket manager_escalation].freeze

  validates :resolution_type, inclusion: { in: VALID_RESOLUTION_TYPES }, allow_blank: true

  def terminal?
    true
  end
end
