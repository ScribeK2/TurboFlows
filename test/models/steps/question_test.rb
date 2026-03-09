require "test_helper"

class Steps::QuestionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "q-test@example.com", password: "password123!", password_confirmation: "password123!")
    @workflow = Workflow.create!(title: "Test", user: @user)
  end

  test "question step requires question text" do
    step = Steps::Question.new(workflow: @workflow, position: 0, title: "Q1")
    assert_not step.valid?
    assert_includes step.errors[:question], "can't be blank"
  end

  test "valid question step" do
    step = Steps::Question.new(workflow: @workflow, position: 0, title: "Q1", question: "What is your name?", answer_type: "text")
    assert step.valid?, step.errors.full_messages.join(", ")
  end

  test "question step auto-generates variable_name from title" do
    step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Customer Name", question: "What is your name?")
    assert_equal "customer_name", step.variable_name
  end

  test "STI type is correct" do
    step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "What?")
    assert_equal "Steps::Question", step.type
    assert_instance_of Steps::Question, Step.find(step.id)
  end
end
