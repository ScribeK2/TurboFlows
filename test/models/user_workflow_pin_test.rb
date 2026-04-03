require "test_helper"

class UserWorkflowPinTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "pinner@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(title: "Pinnable Flow", user: @user)
  end

  test "valid pin" do
    pin = UserWorkflowPin.new(user: @user, workflow: @workflow)
    assert pin.valid?
  end

  test "belongs to user" do
    pin = UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_equal @user, pin.user
  end

  test "belongs to workflow" do
    pin = UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_equal @workflow, pin.workflow
  end

  test "prevents duplicate pins for same user and workflow" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    duplicate = UserWorkflowPin.new(user: @user, workflow: @workflow)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "allows same workflow pinned by different users" do
    other_user = User.create!(
      email: "other@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    pin = UserWorkflowPin.new(user: other_user, workflow: @workflow)
    assert pin.valid?
  end

  test "enforces pin limit of #{UserWorkflowPin::MAX_PINS}" do
    UserWorkflowPin::MAX_PINS.times do |i|
      wf = Workflow.create!(title: "Flow #{i}", user: @user)
      UserWorkflowPin.create!(user: @user, workflow: wf)
    end

    extra_wf = Workflow.create!(title: "One Too Many", user: @user)
    pin = UserWorkflowPin.new(user: @user, workflow: extra_wf)
    assert_not pin.valid?
    assert_includes pin.errors[:base], "You can pin up to #{UserWorkflowPin::MAX_PINS} workflows"
  end

  test "cascade destroys when workflow is deleted" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_difference "UserWorkflowPin.count", -1 do
      @workflow.destroy
    end
  end

  test "cascade destroys when user is deleted" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_difference "UserWorkflowPin.count", -1 do
      @user.destroy
    end
  end

  test "user has pinned_workflows association" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_includes @user.pinned_workflows, @workflow
  end
end
