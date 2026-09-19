require "test_helper"

module Steps
  # An option's `value` is what a Transition condition matches on
  # (`variable == 'wrong_password'`), while its `label` is what the agent reads.
  # The builder offers both as two bare fields, so a first-timer routinely fills
  # in only the label — and a blank value is a branch that can never fire, built
  # silently. The value now falls back to the label, so the split is opt-in:
  # spell a value out only when it has to differ from what the agent sees.
  class QuestionOptionValuesTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "test-option-values@example.com", password: "password123456")
      @workflow = Workflow.create!(title: "Option Values", user: @user)
    end

    test "a label-only option takes its label as its value" do
      step = build_question([{ "label" => "Wrong password", "value" => "" }])
      step.save!

      assert_equal "Wrong password", step.options.first["value"]
    end

    test "an explicit value is left alone" do
      step = build_question([{ "label" => "Wrong password", "value" => "wrong_password" }])
      step.save!

      assert_equal "wrong_password", step.options.first["value"]
    end

    test "a missing value key is filled in, not just a blank one" do
      step = build_question([{ "label" => "Account locked" }])
      step.save!

      assert_equal "Account locked", step.options.first["value"]
    end

    test "whitespace counts as blank" do
      step = build_question([{ "label" => "Something else", "value" => "   " }])
      step.save!

      assert_equal "Something else", step.options.first["value"]
    end

    test "each option is filled independently" do
      step = build_question([
                              { "label" => "Wrong password", "value" => "" },
                              { "label" => "Account locked", "value" => "locked" },
                              { "label" => "Something else" }
                            ])
      step.save!

      assert_equal(["Wrong password", "locked", "Something else"],
                   step.options.pluck("value"))
    end

    # An option with no label has nothing to fall back to. It stays blank rather
    # than inventing one, and the health check reports it.
    test "an option with neither label nor value is left blank" do
      step = build_question([{ "label" => "", "value" => "" }])
      step.save!

      assert_equal "", step.options.first["value"].to_s
    end

    test "symbol keys from a non-form writer are handled" do
      step = build_question([{ label: "Yes", value: nil }])
      step.save!

      assert_equal "Yes", step.options.first["value"]
    end

    test "nil options is left alone" do
      step = Steps::Question.new(workflow: @workflow, title: "Q", position: 0, options: nil)
      assert step.save
      assert_nil step.options
    end

    test "a non-array options value is left alone rather than raising" do
      step = Steps::Question.new(workflow: @workflow, title: "Q", position: 0, options: "nonsense")
      assert step.save
    end

    test "the fallback survives a later edit that blanks the value again" do
      step = build_question([{ "label" => "Wrong password", "value" => "wrong_password" }])
      step.save!

      step.update!(options: [{ "label" => "Wrong password", "value" => "" }])

      assert_equal "Wrong password", step.options.first["value"]
    end

    # 2026-09-19 (decision A5): padded label and value are trimmed on save.
    # ConditionEvaluator strips the CONDITION's value when it reads one, but
    # compares the ANSWER raw — and the runner submits an option's saved
    # value, padding included, as that raw answer. Trimming at save is what
    # keeps a condition built from the value matching its own answer.
    test "a padded label and value are both trimmed" do
      step = build_question([{ "label" => " Router ", "value" => " router " }])
      step.save!

      assert_equal "Router", step.options.first["label"]
      assert_equal "router", step.options.first["value"]
    end

    # The fallback reads the ALREADY-trimmed label, so a padded label-only
    # option derives a value with no padding of its own.
    test "a padded label-only option derives a trimmed value from the trimmed label" do
      step = build_question([{ "label" => " Modem " }])
      step.save!

      assert_equal "Modem", step.options.first["label"]
      assert_equal "Modem", step.options.first["value"]
    end

    test "a whitespace-only label is left exactly as blank as it always was" do
      step = build_question([{ "label" => "   ", "value" => "" }])
      step.save!

      assert_equal "", step.options.first["label"].to_s.strip
      assert_equal "", step.options.first["value"].to_s
    end

    # Reassigning `options` on every save is a no-op for dirty tracking once the
    # data is already clean: ActiveRecord's `json` type compares the cast value,
    # not object identity, so a save that touches only some other field must not
    # also register `options` as changed (and so must not bump lock_version for
    # no reason).
    test "resaving already-trimmed options does not register options as changed" do
      step = build_question([{ "label" => "Router", "value" => "router" }])
      step.save!
      version_before = step.lock_version

      # Reloaded, not the same in-memory record: the realistic path is a
      # persisted step loaded fresh and one other field autosaved on it, not
      # a record that never left memory since the first save.
      reloaded = Steps::Question.find(step.id)
      reloaded.update!(title: "Which sign-in error? (edited)")

      assert_not reloaded.saved_changes.key?("options")
      assert_equal version_before + 1, reloaded.lock_version
    end

    private

    def build_question(options)
      Steps::Question.new(
        workflow: @workflow,
        title: "Which sign-in error?",
        position: 0,
        answer_type: "multiple_choice",
        options: options
      )
    end
  end
end
