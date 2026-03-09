class Steps::Escalate < Step
  VALID_TARGET_TYPES = %w[team queue supervisor channel department ticket].freeze
  VALID_PRIORITIES = %w[low medium normal high urgent critical].freeze

  has_rich_text :notes

  validates :target_type, inclusion: { in: VALID_TARGET_TYPES }, allow_blank: true
  validates :priority, inclusion: { in: VALID_PRIORITIES }, allow_blank: true
end
