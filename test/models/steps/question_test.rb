require "test_helper"

class Steps::QuestionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "test-question@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Question Test", user: @user)
  end

  test "valid with title only (draft mode)" do
    step = Steps::Question.new(workflow: @workflow, title: "Ask name", position: 0)
    assert step.valid?
  end

  test "auto-generates variable_name from title" do
    step = Steps::Question.create!(workflow: @workflow, title: "Customer Name", position: 0)
    assert_equal "customer_name", step.variable_name
  end

  test "does not overwrite manually set variable_name" do
    step = Steps::Question.create!(workflow: @workflow, title: "Customer Name", position: 0, variable_name: "cust_name")
    assert_equal "cust_name", step.variable_name
  end

  test "outcome_summary includes question and variable" do
    step = Steps::Question.create!(workflow: @workflow, title: "Q1", question: "What is your name?", variable_name: "name", answer_type: "free_text", position: 0)
    summary = step.outcome_summary
    assert_includes summary, "What is your name?"
    assert_includes summary, "name"
  end

  test "outcome_summary with answer_type" do
    step = Steps::Question.create!(workflow: @workflow, title: "Q1", question: "Pick one", answer_type: "multiple_choice", position: 0)
    summary = step.outcome_summary
    assert_includes summary, "Multiple Choice"
  end

  test "step_type returns question" do
    step = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    assert_equal "question", step.step_type
  end
end
