require "test_helper"

class TransitionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "test-transition@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Transition Test", user: @user)
    @step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    @step2 = Steps::Action.create!(workflow: @workflow, title: "A1", position: 1)
  end

  test "belongs to step and target_step" do
    t = Transition.create!(step: @step1, target_step: @step2)
    assert_equal @step1, t.step
    assert_equal @step2, t.target_step
  end

  test "requires step" do
    t = Transition.new(target_step: @step2)
    assert_not t.valid?
  end

  test "requires target_step" do
    t = Transition.new(step: @step1)
    assert_not t.valid?
  end

  test "rejects duplicate step+target+condition" do
    Transition.create!(step: @step1, target_step: @step2, condition: "yes")
    dup = Transition.new(step: @step1, target_step: @step2, condition: "yes")
    assert_not dup.valid?
  end

  test "allows same step pair with different conditions" do
    Transition.create!(step: @step1, target_step: @step2, condition: "yes")
    t2 = Transition.new(step: @step1, target_step: @step2, condition: "no")
    assert_predicate t2, :valid?
  end

  test "allows same step with different targets" do
    step3 = Steps::Message.create!(workflow: @workflow, title: "M1", position: 2)
    Transition.create!(step: @step1, target_step: @step2)
    t2 = Transition.new(step: @step1, target_step: step3)
    assert_predicate t2, :valid?
  end

  test "rejects transition between steps in different workflows" do
    other_workflow = Workflow.create!(title: "Other", user: @user)
    other_step = Steps::Question.create!(workflow: other_workflow, title: "Q", position: 0)
    t = Transition.new(step: @step1, target_step: other_step)
    assert_not t.valid?
    assert_includes t.errors[:target_step], "must belong to the same workflow"
  end

  test "allows transition between steps in same workflow" do
    t = Transition.new(step: @step1, target_step: @step2)
    assert_predicate t, :valid?
  end

  test "default scope orders by position" do
    step3 = Steps::Message.create!(workflow: @workflow, title: "M1", position: 2)
    t2 = Transition.create!(step: @step1, target_step: step3, position: 0)
    t1 = Transition.create!(step: @step1, target_step: @step2, position: 1)
    assert_equal [t2, t1], @step1.transitions.to_a
  end

  test "deleting transition does not affect steps" do
    t = Transition.create!(step: @step1, target_step: @step2)
    t.destroy!
    assert Steps::Question.exists?(@step1.id)
    assert Steps::Action.exists?(@step2.id)
  end
end
