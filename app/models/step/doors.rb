class Step
  # The ways out of a step, worked out from the step itself: a Yes/No Question
  # has a Yes and a No whether or not anyone has connected them. A door with no
  # transition behind it is a stub - something the builder can show and offer to
  # fill. Nothing here is stored; stubs are not rows.
  #
  # A door is wired when StepResolver would take that transition for that answer,
  # so matching reads conditions as loosely as the runner does: case, spacing and
  # quote style are ignored, and a bare value ("yes") counts.
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
      @transitions = step.transitions.to_a.sort_by { |t| [t.position || 0, t.id || 0] }
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
    # the step no longer offers - an edge that can never fire.
    def unmatched_extras
      return [] if answers.empty?

      extras.filter_map do |transition|
        parsed = parse(transition.condition)
        [transition, parsed[:value]] if parsed && parsed[:operator] == "==" && own_variable?(parsed[:variable])
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
      return normalize(text) == normalize(value) unless text.match?(/[=!<>]/)

      parsed = parse(text)
      parsed.present? && parsed[:operator] == "==" && own_variable?(parsed[:variable]) &&
        normalize(parsed[:value]) == normalize(value)
    end

    def parse(condition)
      ConditionEvaluator.new(condition).parse
    end

    def normalize(text)
      text.to_s.delete(%q('"\\)).strip.downcase
    end
  end
end
