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
