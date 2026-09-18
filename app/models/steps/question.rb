module Steps
  class Question < Step
    # The answer types the builder offers and the import schema publishes.
    # Order is the order the editor renders them in.
    VALID_ANSWER_TYPES = %w[text yes_no multiple_choice dropdown date number].freeze

    before_validation :generate_variable_name, if: -> { variable_name.blank? && title.present? }
    before_validation :default_option_values_to_labels
    after_update :carry_conditions_to_new_variable, if: :saved_change_to_variable_name?

    def outcome_summary
      parts = []
      parts << answer_type&.titleize if answer_type.present?
      parts << question.truncate(80) if question.present?
      parts << "{{#{variable_name}}}" if variable_name.present?
      parts.join(": ")
    end

    # Public so GrowStep can build a name and make it unique before the save;
    # the callback below still covers every other writer.
    def self.variable_name_from(title)
      title.to_s.strip
           .gsub(/[?!.,;:'"(){}\[\]]/, "")
           .parameterize(separator: "_")
           .tr("-", "_").squeeze("_")
           .gsub(/^_|_$/, "")
           .first(30)
           .gsub(/_$/, "")
    end

    # The one rewrite #carry_conditions_to_new_variable and TransitionSync both
    # apply: a condition whose leading identifier names old_name exactly becomes
    # new_name; anything else - another variable, a bare value with no operator,
    # a blank condition - is returned unchanged. Public so TransitionSync can
    # apply the same rewrite the panel's own stale snapshot needs, without a
    # second copy of the exact-match logic.
    def self.rewrite_condition_variable(condition, old_name, new_name)
      return condition if condition.blank?

      parsed = ConditionEvaluator.new(condition).parse
      return condition unless parsed && parsed[:variable] == old_name

      condition.sub(/\A\s*#{Regexp.escape(old_name)}\b/, new_name)
    end

    # nil unless THIS save renamed the variable; otherwise [old_name, new_name],
    # with a blank old name normalised to WorkflowVariableNames::LEGACY_ANSWER -
    # the name condition_preset_controller.js writes for a Question with no
    # variable_name yet, so a stale condition naming it is a stale condition on
    # THIS Question, not on nothing. The one place that normalisation happens:
    # #carry_conditions_to_new_variable and StepsController#update both read
    # the pair from here rather than repeating it.
    def renamed_variable_pair
      return nil unless saved_change_to_variable_name?

      old_name, new_name = saved_change_to_variable_name
      return nil if new_name.blank?

      [old_name.presence || WorkflowVariableNames::LEGACY_ANSWER, new_name]
    end

    private

    # A Transition matches on an option's `value`, never on its `label`, but the
    # panel offers the two as bare fields side by side with nothing saying which
    # is which. Filling in only the label therefore built a branch that could
    # never fire, and nothing reported it. Falling back to the label makes the
    # split opt-in: spell a value out only when it must differ from what the
    # agent reads. Runs on every save, so blanking a value re-derives it rather
    # than leaving the option unmatchable.
    #
    # An option with no label has nothing to fall back to and is left alone —
    # WorkflowHealthCheck reports that one.
    def default_option_values_to_labels
      return unless options.is_a?(Array)

      self.options = options.map do |option|
        next option unless option.is_a?(Hash)

        label = option["label"] || option[:label]
        value = option["value"] || option[:value]
        next option if value.to_s.strip.present? || label.to_s.strip.blank?

        option.merge(option.key?(:label) ? { value: label } : { "value" => label })
      end
    end

    def generate_variable_name
      self.variable_name = self.class.variable_name_from(title)
    end

    # Doors are written as "<variable> == 'yes'", and a builder-made Question is
    # named untitled_question - a name people change. Its own connections follow
    # the rename in the same save; a condition on another step that reads this
    # variable is that step's to fix, and :undefined_variable reports it.
    def carry_conditions_to_new_variable
      pair = renamed_variable_pair
      return unless pair

      old_name, new_name = pair
      transitions.includes(:target_step).each do |transition|
        rewritten = self.class.rewrite_condition_variable(transition.condition, old_name, new_name)
        transition.update!(condition: rewritten) if rewritten != transition.condition
      end
    end
  end
end
