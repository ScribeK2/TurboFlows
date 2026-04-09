require "test_helper"

class WorkflowConcurrencyTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(
      title: "Concurrent Test",
      user: @user,
      status: "draft"
    )
    Steps::Question.create!(workflow: @workflow, position: 0, title: "Step 1", question: "Initial?")
  end

  test "lock_version increments on save" do
    initial_version = @workflow.lock_version

    @workflow.update!(title: "Updated Title")

    assert_equal initial_version + 1, @workflow.lock_version

    @workflow.update!(title: "Updated Again")

    assert_equal initial_version + 2, @workflow.lock_version
  end

  test "optimistic locking raises StaleObjectError on version mismatch" do
    # Load two instances of the same workflow
    workflow1 = Workflow.find(@workflow.id)
    workflow2 = Workflow.find(@workflow.id)

    # Both have the same initial version
    assert_equal workflow1.lock_version, workflow2.lock_version

    # First update succeeds
    workflow1.update!(title: "Update from instance 1")

    # Second update should fail because lock_version changed
    workflow2.title = "Update from instance 2"

    assert_raises(ActiveRecord::StaleObjectError) do
      workflow2.save!
    end
  end

  test "concurrent workflow modifications are protected by optimistic locking" do
    workflow1 = Workflow.find(@workflow.id)
    workflow2 = Workflow.find(@workflow.id)

    # First user updates the workflow title
    workflow1.update!(title: "Updated by user 1")

    # Second user tries to update (based on stale lock_version)
    workflow2.title = "Updated by user 2"

    # This should raise an error because lock_version mismatches
    assert_raises(ActiveRecord::StaleObjectError) do
      workflow2.save!
    end

    # Reload to verify only the first update succeeded
    @workflow.reload

    assert_equal "Updated by user 1", @workflow.title
  end

  test "reload resets lock_version for retry" do
    workflow1 = Workflow.find(@workflow.id)
    workflow2 = Workflow.find(@workflow.id)

    # First user updates
    workflow1.update!(title: "First update")

    # Second user's save fails
    workflow2.title = "Second update"
    assert_raises(ActiveRecord::StaleObjectError) do
      workflow2.save!
    end

    # After reload, second user can save
    workflow2.reload

    assert_equal workflow1.lock_version, workflow2.lock_version

    workflow2.title = "Second update after reload"

    assert workflow2.save
    assert_equal "Second update after reload", workflow2.title
  end

  test "save without validation still increments lock_version" do
    initial_version = @workflow.lock_version

    # This simulates what autosave does
    @workflow.title = "Autosaved title"
    @workflow.save(validate: false)

    assert_equal initial_version + 1, @workflow.lock_version
  end

  test "multiple rapid updates increment lock_version correctly" do
    initial_version = @workflow.lock_version

    10.times do |i|
      @workflow.update!(title: "Update #{i}")
    end

    assert_equal initial_version + 10, @workflow.lock_version
  end

  test "transaction with lock prevents concurrent modifications" do
    # This tests the pattern used in WorkflowChannel#autosave
    workflow1 = Workflow.find(@workflow.id)

    # Simulate first user locking and updating
    Workflow.transaction do
      workflow1.lock!
      workflow1.title = "Locked update"
      workflow1.save!
    end

    # Verify the update succeeded
    @workflow.reload

    assert_equal "Locked update", @workflow.title
    assert_operator @workflow.lock_version, :>=, 1, "lock_version should have incremented"
  end
end
