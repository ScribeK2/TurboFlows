require "test_helper"

class StepPositionableTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "pos-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Position Test WF", user: @user)
  end

  test "assign_next_position sets position on create when blank" do
    s1 = Steps::Action.create!(workflow: @workflow, title: "First")
    assert_equal 0, s1.position

    s2 = Steps::Action.create!(workflow: @workflow, title: "Second")
    assert_equal 1, s2.position

    s3 = Steps::Action.create!(workflow: @workflow, title: "Third")
    assert_equal 2, s3.position
  end

  test "assign_next_position does not override explicit position" do
    s1 = Steps::Action.create!(workflow: @workflow, position: 5, title: "Explicit")
    assert_equal 5, s1.position
  end

  test "insert_at shifts positions of later steps" do
    s1 = Steps::Action.create!(workflow: @workflow, position: 0, title: "A")
    s2 = Steps::Action.create!(workflow: @workflow, position: 1, title: "B")
    s3 = Steps::Action.create!(workflow: @workflow, position: 2, title: "C")

    Step.insert_at(@workflow, 1)

    assert_equal 0, s1.reload.position
    assert_equal 2, s2.reload.position
    assert_equal 3, s3.reload.position
  end

  test "rebalance_positions removes gaps" do
    s1 = Steps::Action.create!(workflow: @workflow, position: 0, title: "A")
    s2 = Steps::Action.create!(workflow: @workflow, position: 5, title: "B")
    s3 = Steps::Action.create!(workflow: @workflow, position: 10, title: "C")

    Step.rebalance_positions(@workflow)

    assert_equal 0, s1.reload.position
    assert_equal 1, s2.reload.position
    assert_equal 2, s3.reload.position
  end
end
