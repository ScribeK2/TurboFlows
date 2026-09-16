require "test_helper"

# The run transcript is read by an agent on a live call, and by whoever reviews
# the call afterwards. It showed the option's *value* — "account_locked" — when
# the agent had clicked a button reading "Account locked". The value is a routing
# token; it should never have been the thing a human reads.
#
# The label is captured onto the execution_path entry at answer time rather than
# looked up when the card renders: steps are edited and deleted after runs, and
# `runner/_thread_row` deliberately reads the snapshot only, so a card built from
# the live Step would replay a call with words nobody ever saw.
class RunnerAnswerLabelTest < ActiveSupport::TestCase
  include RunnerHelper

  setup do
    @user = User.create!(email: "answer-label@example.com", password: "password123456", role: "editor")
    @workflow = Workflow.create!(title: "Answer labels", user: @user)
    @question = Steps::Question.create!(
      workflow: @workflow, title: "Which sign-in error?", position: 1,
      question: "Read the exact message.", answer_type: "multiple_choice",
      variable_name: "sign_in_error",
      options: [
        { "label" => "Account locked", "value" => "account_locked" },
        { "label" => "Wrong password", "value" => "wrong_password" }
      ]
    )
    @resolve = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2, resolution_type: "success")
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)
  end

  test "answering records the label the agent clicked, not just the value" do
    scenario = run_answer("account_locked")
    entry = question_entry(scenario)

    assert_equal "account_locked", entry["answer"], "the routing value must still be recorded"
    assert_equal "Account locked", entry["answer_label"]
  end

  test "the transcript row shows the label" do
    scenario = run_answer("account_locked")

    assert_equal "Account locked", runner_row_summary(question_entry(scenario))
  end

  test "an answer with no matching option falls back to what was given" do
    scenario = run_answer("something_typed")

    assert_equal "something_typed", runner_row_summary(question_entry(scenario))
  end

  # Runs recorded before this existed have no answer_label key at all.
  test "an older entry with no answer_label still renders its answer" do
    assert_equal "account_locked",
                 runner_row_summary({ "step_type" => "question", "answer" => "account_locked" })
  end

  test "a free-text question is unaffected" do
    @question.update!(answer_type: "text", options: nil)
    scenario = run_answer("they forgot it")

    assert_equal "they forgot it", runner_row_summary(question_entry(scenario))
  end

  private

  # Through Scenario#process_step, the real entry point — it builds the
  # path_entry the processor writes into, so a test that calls the processor
  # directly is testing a shape the app never produces.
  def run_answer(answer)
    scenario = Scenario.create!(workflow: @workflow, user: @user, current_node_uuid: @question.uuid)
    scenario.process_step(answer)
    scenario.reload
  end

  def question_entry(scenario)
    Array(scenario.execution_path).find { |e| e["step_type"] == "question" }
  end
end
