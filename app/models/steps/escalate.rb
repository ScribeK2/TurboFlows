module Steps
  class Escalate < Step
    VALID_TARGET_TYPES = %w[team queue supervisor channel department ticket].freeze
    VALID_PRIORITIES = %w[low medium high urgent critical].freeze

    has_rich_text :notes

    validates :target_type, inclusion: { in: VALID_TARGET_TYPES }, allow_blank: true
    validates :priority, inclusion: { in: VALID_PRIORITIES }, allow_blank: true

    def outcome_summary
      parts = []
      parts << priority&.capitalize if priority.present?
      parts << "-> #{target_type}: #{target_value}" if target_type.present?
      parts.join(" ")
    end
  end
end
