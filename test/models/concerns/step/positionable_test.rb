require "test_helper"

class Step::PositionableTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "test-pos@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Position Test", user: @user)
  end

  test "auto-assigns position 0 to first step" do
    step = Steps::Question.create!(workflow: @workflow, title: "First")
    assert_equal 0, step.position
  end

  test "auto-assigns incrementing positions" do
    s1 = Steps::Question.create!(workflow: @workflow, title: "S1")
    s2 = Steps::Action.create!(workflow: @workflow, title: "S2")
    s3 = Steps::Message.create!(workflow: @workflow, title: "S3")
    assert_equal 0, s1.position
    assert_equal 1, s2.position
    assert_equal 2, s3.position
  end

  test "insert_at shifts subsequent positions up" do
    s1 = Steps::Question.create!(workflow: @workflow, title: "S1")
    s2 = Steps::Action.create!(workflow: @workflow, title: "S2")
    s3 = Steps::Message.create!(workflow: @workflow, title: "S3")
    Step.insert_at(@workflow, 1)
    assert_equal 0, s1.reload.position
    assert_equal 2, s2.reload.position
    assert_equal 3, s3.reload.position
  end

  test "insert_at at position 0 shifts all positions up" do
    s1 = Steps::Question.create!(workflow: @workflow, title: "S1")
    s2 = Steps::Action.create!(workflow: @workflow, title: "S2")
    Step.insert_at(@workflow, 0)
    assert_equal 1, s1.reload.position
    assert_equal 2, s2.reload.position
  end

  test "rebalance_positions re-indexes with gaps" do
    s1 = Steps::Question.create!(workflow: @workflow, title: "S1")
    s2 = Steps::Action.create!(workflow: @workflow, title: "S2")
    s3 = Steps::Message.create!(workflow: @workflow, title: "S3")
    s1.update_column(:position, 0)
    s2.update_column(:position, 5)
    s3.update_column(:position, 10)
    Step.rebalance_positions(@workflow)
    assert_equal 0, s1.reload.position
    assert_equal 1, s2.reload.position
    assert_equal 2, s3.reload.position
  end

  test "rebalance after deletion leaves no gaps" do
    s1 = Steps::Question.create!(workflow: @workflow, title: "S1")
    s2 = Steps::Action.create!(workflow: @workflow, title: "S2")
    s3 = Steps::Message.create!(workflow: @workflow, title: "S3")
    s2.destroy!
    Step.rebalance_positions(@workflow)
    assert_equal 0, s1.reload.position
    assert_equal 1, s3.reload.position
  end
end
