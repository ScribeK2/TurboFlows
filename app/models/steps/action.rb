class Steps::Action < Step
  has_rich_text :instructions

  def outcome_summary
    text = instructions&.to_plain_text&.truncate(80)
    parts = []
    parts << action_type if action_type.present?
    parts << text if text.present?
    parts.join(": ")
  end
end
