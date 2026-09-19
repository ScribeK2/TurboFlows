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

  test "gets a uuid when none is given" do
    t = Transition.create!(step: @step1, target_step: @step2)
    assert_match(/\A[0-9a-f-]{36}\z/, t.uuid)
  end

  test "keeps a uuid it is given" do
    uuid = SecureRandom.uuid
    t = Transition.create!(step: @step1, target_step: @step2, uuid: uuid)
    assert_equal uuid, t.reload.uuid
  end

  test "refuses a malformed uuid" do
    t = Transition.new(step: @step1, target_step: @step2, uuid: "nope")
    assert_not t.valid?
    assert_predicate t.errors[:uuid], :any?
  end

  test "refuses a uuid another transition holds" do
    first = Transition.create!(step: @step1, target_step: @step2)
    dup = Transition.new(step: @step2, target_step: @step1, uuid: first.uuid)
    assert_not dup.valid?
  end

  test "settle_positions puts every blank condition after every conditional" do
    step3 = Steps::Action.create!(workflow: @workflow, title: "A2", position: 2)
    default = Transition.create!(step: @step1, target_step: @step2, position: 0)
    yes = Transition.create!(step: @step1, target_step: step3, condition: "q1 == 'yes'", position: 1)

    Transition.settle_positions(@step1)

    assert_equal [yes.id, default.id], @step1.transitions.reload.map(&:id)
    assert_equal [0, 1], @step1.transitions.map(&:position)
  end

  test "settle_positions keeps the order of conditionals among themselves" do
    step3 = Steps::Action.create!(workflow: @workflow, title: "A2", position: 2)
    a = Transition.create!(step: @step1, target_step: @step2, condition: "q1 == 'a'", position: 0)
    b = Transition.create!(step: @step1, target_step: step3, condition: "q1 == 'b'", position: 5)

    Transition.settle_positions(@step1)

    assert_equal [a.id, b.id], @step1.transitions.reload.map(&:id)
    assert_equal [0, 1], @step1.transitions.map(&:position)
  end

  # Both callers wrap it in their own transaction; a third must not have to
  # know that. One row that cannot be saved must not leave the rows before it
  # renumbered and the rows after it not.
  test "settle_positions moves every row or none" do
    step3 = Steps::Action.create!(workflow: @workflow, title: "A2", position: 2)
    elsewhere = Steps::Action.create!(workflow: Workflow.create!(title: "Elsewhere", user: @user),
                                      title: "Foreign", position: 0)
    Transition.create!(step: @step1, target_step: @step2, position: 0)
    Transition.create!(step: @step1, target_step: @step2, condition: "q1 == 'a'", position: 1)
    broken = Transition.create!(step: @step1, target_step: step3, condition: "q1 == 'b'", position: 2)
    broken.update_columns(target_step_id: elsewhere.id)

    assert_raises(ActiveRecord::RecordInvalid) { Transition.settle_positions(@step1) }

    assert_equal [0, 1, 2], @step1.transitions.reload.order(:id).map(&:position)
  end
end
