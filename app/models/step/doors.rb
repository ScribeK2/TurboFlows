class Step
  # The ways out of a step, worked out from the step itself: a Yes/No Question
  # has a Yes and a No whether or not anyone has connected them. A door with no
  # transition behind it is a stub - something the builder can show and offer to
  # fill. Nothing here is stored; stubs are not rows.
  #
  # A door is wired when StepResolver would take that transition for that
  # answer, so matching reads a condition the way the runner does - case and
  # spacing ignored, either quote style on the CONDITION side, a bare value
  # ("yes") accepted - and no more loosely than that. The door's own value
  # stands in for the answer the runner would compare against, and the runner
  # compares an answer raw: quote characters in a door's value are never
  # stripped, only case and surrounding whitespace. So a value containing an
  # apostrophe or a literal quote character is read as wired only when it
  # would actually match at runtime - see #reads_as?.
  class Doors
    Door = Data.define(:kind, :label, :value, :condition, :transition) do
      def target_step = transition&.target_step
      def stub? = transition.nil?
    end

    LEGACY_VARIABLE = WorkflowVariableNames::LEGACY_ANSWER
    OPTION_TYPES = %w[multiple_choice dropdown].freeze

    def self.for(step)
      new(step)
    end

    def initialize(step)
      @step = step
      # A wired door's #target_step reads every one of these - the panel's
      # doors list would otherwise fire one query per wired door. But
      # `.includes` on an association proxy always issues a fresh query, even
      # when the association is already loaded - so once a row builds a Doors
      # per step (workflows/_step_row), that "one query per wired door" became
      # one query per STEP instead, on every render of the list. loaded? mirrors
      # the guard _step_row.html.erb used before Doors existed: reuse the
      # caller's preload (transitions: :target_step, so target_step comes for
      # free too) when there is one, and only query here for a single step
      # (the panel, a lone row re-render) that never preloaded anything.
      transitions = step.transitions.loaded? ? step.transitions : step.transitions.includes(:target_step)
      @transitions = transitions.to_a.sort_by { |t| [t.position || 0, t.id || 0] }
    end

    def growable?
      !@step.is_a?(Steps::Resolve) && !@step.hands_off?
    end

    def doors
      @doors ||= growable? ? build : []
    end

    def stubs = doors.select(&:stub?)

    def extras
      claimed = doors.filter_map(&:transition)
      @transitions.reject { |t| claimed.include?(t) }
    end

    # The wired blank-condition door: where an answer with no door of its own goes.
    def fallback
      doors.find { |door| door.kind != :answer && !door.stub? }
    end

    # Answers a run could give that lead nowhere. Empty while nothing at all is
    # wired - :no_outgoing_transitions already says that, once.
    def missing
      return [] if @transitions.empty? || fallback

      stubs.select { |door| door.kind == :answer }
    end

    def door_for(condition)
      if condition.blank?
        doors.find { |door| door.kind != :answer }
      else
        doors.find { |door| door.kind == :answer && reads_as?(condition, door.value) }
      end
    end

    # [transition, value] for a condition on THIS step's answer naming a value
    # the step no longer offers - an edge that can never fire. An extra whose
    # value DOES match a current answer is not stale - a hand-made duplicate
    # of a wired door's own condition (see "a hand-made duplicate of a wired
    # door is an extra" in the test) is a repeat, not a value the step stopped
    # offering, so both branches below exclude it the same way #build claims a
    # door: by checking the value against every current answer, not merely
    # against whichever answer the same condition happened to claim first.
    #
    # A bare condition (no [=!<>]) is checked the same way #reads_as? checks
    # one: ConditionEvaluator#parse returns nil for it, so the operator-form
    # branch below never saw it, yet StepResolver's simple-value match honours
    # it at runtime. A bare value that DOES equal an answer is already claimed
    # as that door by #build, so it never reaches +extras+ at all - only a
    # bare value matching no answer lands here.
    def unmatched_extras
      return [] if answers.empty?

      extras.filter_map do |transition|
        text = transition.condition.to_s.strip
        next if text.blank?

        if text.match?(/[=!<>]/)
          parsed = parse(text)
          next unless parsed && parsed[:operator] == "==" && own_variable?(parsed[:variable])

          [transition, parsed[:value]] unless answers.any? { |_, value| operator_match?(parsed[:value], value) }
        else
          [transition, text] unless answers.any? { |_, value| bare_match?(text, value) }
        end
      end
    end

    def needs_options?
      @step.is_a?(Steps::Question) && OPTION_TYPES.include?(@step.answer_type) && answers.empty?
    end

    private

    def build
      return [blank_door(:next, "Next")] if answers.empty?

      claimed = []
      built = answers.map do |label, value|
        transition = @transitions.find { |t| claimed.exclude?(t) && reads_as?(t.condition, value) }
        claimed << transition if transition
        Door.new(kind: :answer, label: label, value: value, condition: condition_for(value), transition: transition)
      end

      default = blank_door(:anything_else, "Anything else")
      default.stub? ? built : built + [default]
    end

    def blank_door(kind, label)
      Door.new(kind: kind, label: label, value: nil, condition: nil,
               transition: @transitions.find { |t| t.condition.blank? })
    end

    # [[label, value], ...]
    def answers
      @answers ||= question_answers
    end

    def question_answers
      return [] unless @step.is_a?(Steps::Question)

      if @step.answer_type == "yes_no"
        [%w[Yes yes], %w[No no]]
      elsif OPTION_TYPES.include?(@step.answer_type)
        Array(@step.options).filter_map do |option|
          label, value = option.is_a?(Hash) ? [option["label"] || option[:label], option["value"] || option[:value]] : [option, option]
          value = value.presence || label
          [label.presence || value, value] if value.to_s.strip.present?
        end
      else
        []
      end
    end

    def variable
      @step.variable_name.presence || LEGACY_VARIABLE
    end

    def own_variable?(name)
      [variable, LEGACY_VARIABLE].include?(name.to_s)
    end

    # The string condition_preset_controller.js#buildPresets writes.
    def condition_for(value)
      "#{variable} == '#{value.to_s.gsub("'") { "\\'" }}'"
    end

    def reads_as?(condition, value)
      text = condition.to_s.strip
      return false if text.blank?
      return bare_match?(text, value) unless text.match?(/[=!<>]/)

      parsed = parse(text)
      parsed.present? && parsed[:operator] == "==" && own_variable?(parsed[:variable]) &&
        operator_match?(parsed[:value], value)
    end

    def parse(condition)
      ConditionEvaluator.new(condition).parse
    end

    # StepResolver's simple-value branch does a plain downcase comparison with
    # no quote stripping (`answer.to_s.downcase == transition.condition.to_s.downcase`),
    # so a condition spelled with quote characters ("'no'") is a literal
    # string to the runner, not a match for the bare answer "no".
    def bare_match?(text, value)
      text.strip.downcase == value.to_s.strip.downcase
    end

    # ConditionEvaluator#evaluate_comparison strips '" only from the CONDITION
    # string's own two halves (both #parse and #evaluate_comparison compute
    # that the same way, so parsed_value already IS that stripped value - no
    # further stripping belongs on this side). The ANSWER side - result_value
    # in the evaluator, this door's value here - is compared raw:
    # `result_value.to_s.downcase`, no quote stripping at all. A door's value
    # containing a literal quote character must therefore keep it, or a door
    # would read as wired for an answer the runner would never match.
    def operator_match?(parsed_value, value)
      parsed_value.to_s.downcase == value.to_s.strip.downcase
    end
  end
end
