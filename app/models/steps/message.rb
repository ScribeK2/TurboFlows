module Steps
  class Message < Step
    has_rich_text :content

    def outcome_summary
      content&.to_plain_text&.truncate(80)
    end
  end
end
