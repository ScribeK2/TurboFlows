require "test_helper"

class StepReordererTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "reorder-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Reorder Test WF", user: @user)
    @s0 = Steps::Action.create!(workflow: @workflow, position: 0, title: "A")
    @s1 = Steps::Action.create!(workflow: @workflow, position: 1, title: "B")
    @s2 = Steps::Message.create!(workflow: @workflow, position: 2, title: "C")
    @s3 = Steps::Action.create!(workflow: @workflow, position: 3, title: "D")
  end

  test "moving step forward shifts intermediate steps back" do
    StepReorderer.call(@workflow, @s0, 2)

    assert_equal 2, @s0.reload.position
    assert_equal 0, @s1.reload.position
    assert_equal 1, @s2.reload.position
    assert_equal 3, @s3.reload.position
  end

  test "moving step backward shifts intermediate steps forward" do
    StepReorderer.call(@workflow, @s3, 1)

    assert_equal 0, @s0.reload.position
    assert_equal 2, @s1.reload.position
    assert_equal 3, @s2.reload.position
    assert_equal 1, @s3.reload.position
  end

  test "moving to same position is a no-op" do
    StepReorderer.call(@workflow, @s1, 1)

    assert_equal 0, @s0.reload.position
    assert_equal 1, @s1.reload.position
    assert_equal 2, @s2.reload.position
    assert_equal 3, @s3.reload.position
  end

  test "clamps negative position to 0" do
    StepReorderer.call(@workflow, @s2, -5)

    assert_equal 0, @s2.reload.position
    assert_equal 1, @s0.reload.position
    assert_equal 2, @s1.reload.position
    assert_equal 3, @s3.reload.position
  end

  test "clamps oversized position to max" do
    StepReorderer.call(@workflow, @s0, 100)

    assert_equal 3, @s0.reload.position
    assert_equal 0, @s1.reload.position
    assert_equal 1, @s2.reload.position
    assert_equal 2, @s3.reload.position
  end
end
