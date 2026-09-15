module Steps
  class Escalate < Step
    VALID_TARGET_TYPES = %w[team queue supervisor channel department ticket].freeze
    VALID_PRIORITIES = %w[low medium high urgent critical].freeze

    has_rich_text :notes

    # Never blank, and "medium" rather than the select's first option: the
    # runner only calls out priorities above medium, so this is the quiet value.
    attribute :priority, :string, default: "medium"
    normalizes :priority, with: ->(priority) { priority.presence || "medium" }, apply_to_nil: true

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
