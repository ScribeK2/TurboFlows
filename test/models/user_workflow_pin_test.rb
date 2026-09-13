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
    assert_predicate pin, :valid?
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
    assert_predicate pin, :valid?
  end

  test "enforces pin limit of #{UserWorkflowPin::MAX_PINS}" do
    UserWorkflowPin::MAX_PINS.times do |i|
      wf = file_in_global(Workflow.create!(title: "Flow #{i}", user: @user))
      UserWorkflowPin.create!(user: @user, workflow: wf)
    end

    extra_wf = file_in_global(Workflow.create!(title: "One Too Many", user: @user))
    pin = UserWorkflowPin.new(user: @user, workflow: extra_wf)
    assert_not pin.valid?
    assert_includes pin.errors[:base], "You can pin up to #{UserWorkflowPin::MAX_PINS} workflows"
  end

  test "does not count a pin on a workflow the viewer can no longer see toward the limit" do
    pinned_workflows = Array.new(UserWorkflowPin::MAX_PINS) do |i|
      file_in_global(Workflow.create!(title: "Flow #{i}", user: @user))
    end
    pinned_workflows.each { |wf| UserWorkflowPin.create!(user: @user, workflow: wf) }

    # One of the pinned workflows is unpublished, so it drops out of visible_to.
    pinned_workflows.first.update!(status: "draft")

    still_visible = file_in_global(Workflow.create!(title: "Still Visible", user: @user))
    pin = UserWorkflowPin.new(user: @user, workflow: still_visible)
    assert_predicate pin, :valid?
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
