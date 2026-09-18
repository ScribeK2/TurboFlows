require "test_helper"

class QuestionVariableRenameTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rename-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Rename", user: @user)
    @question = Steps::Question.create!(workflow: @workflow, title: "Untitled Question", position: 0,
                                        answer_type: "yes_no", variable_name: "untitled_question")
    @a = Steps::Action.create!(workflow: @workflow, title: "A", position: 1)
    @b = Steps::Action.create!(workflow: @workflow, title: "B", position: 2)
  end

  test "renaming the variable carries this step's own conditions with it" do
    yes = Transition.create!(step: @question, target_step: @a, condition: "untitled_question == 'yes'")
    no = Transition.create!(step: @question, target_step: @b, condition: "untitled_question=='no'")

    @question.update!(variable_name: "light_green")

    assert_equal "light_green == 'yes'", yes.reload.condition
    assert_equal "light_green=='no'", no.reload.condition
  end

  test "a condition on some other variable is left alone" do
    other = Transition.create!(step: @question, target_step: @a, condition: "tier == 'gold'")
    @question.update!(variable_name: "light_green")
    assert_equal "tier == 'gold'", other.reload.condition
  end

  test "a longer name that starts the same way is not rewritten" do
    other = Transition.create!(step: @question, target_step: @a, condition: "untitled_question_2 == 'yes'")
    @question.update!(variable_name: "light_green")
    assert_equal "untitled_question_2 == 'yes'", other.reload.condition
  end

  test "another step's condition on this variable is not touched" do
    elsewhere = Transition.create!(step: @a, target_step: @b, condition: "untitled_question == 'yes'")
    @question.update!(variable_name: "light_green")
    assert_equal "untitled_question == 'yes'", elsewhere.reload.condition
  end

  test "legacy `answer` conditions follow a first real name" do
    legacy = Steps::Question.create!(workflow: @workflow, title: "Legacy", position: 3, answer_type: "yes_no")
    Steps::Question.where(id: legacy.id).update_all(variable_name: nil)
    legacy.reload
    assert_nil legacy.variable_name

    edge = Transition.create!(step: legacy, target_step: @a, condition: "answer == 'yes'")

    legacy.update!(variable_name: "power")

    assert_equal "power == 'yes'", edge.reload.condition
  end

  test "renaming the title alone rewrites nothing" do
    yes = Transition.create!(step: @question, target_step: @a, condition: "untitled_question == 'yes'")
    @question.update!(title: "Is the light green?")
    assert_equal "untitled_question", @question.variable_name
    assert_equal "untitled_question == 'yes'", yes.reload.condition
  end

  # --- Steps::Question.rewrite_condition_variable ------------------------------
  # The one rewrite TransitionSync and the rename callback both use, tested on
  # its own so the edge cases are pinned independent of either caller.

  test "rewrite_condition_variable replaces only an exact leading match" do
    assert_equal "light_green == 'yes'",
                 Steps::Question.rewrite_condition_variable("untitled_question == 'yes'",
                                                            "untitled_question", "light_green")
    assert_equal "untitled_question_2 == 'yes'",
                 Steps::Question.rewrite_condition_variable("untitled_question_2 == 'yes'",
                                                            "untitled_question", "light_green")
  end

  test "rewrite_condition_variable preserves the condition's own spacing" do
    assert_equal "y=='no'", Steps::Question.rewrite_condition_variable("x=='no'", "x", "y")
  end

  test "rewrite_condition_variable leaves a bare value or a blank condition untouched" do
    assert_equal "modem", Steps::Question.rewrite_condition_variable("modem", "modem", "router")
    assert_nil Steps::Question.rewrite_condition_variable(nil, "x", "y")
    assert_equal "", Steps::Question.rewrite_condition_variable("", "x", "y")
  end

  # Finding 3: the string form of #sub interprets \1, \\ etc. in the
  # replacement as backreferences. A new name that happens to contain a
  # backslash sequence must come through literally, not be reinterpreted.
  test "rewrite_condition_variable passes a backslash in the new name through literally" do
    new_name = 'a\1b'
    assert_equal "a\\1b == 'yes'",
                 Steps::Question.rewrite_condition_variable("x == 'yes'", "x", new_name)
  end
end
