require "test_helper"

# A Resolve step is always some resolution type and an Escalate step always some
# priority. The panel's controls used to show a value the column did not hold,
# and the first autosave then stamped whatever the control's first option was.
class StepDefaultsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "defaults-#{SecureRandom.hex(4)}@example.com", password: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Defaults", user: @user)
  end

  test "a new Resolve step is a success until told otherwise" do
    step = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 0)

    assert_equal "success", step.reload.resolution_type
  end

  test "a blank resolution type is read as success" do
    step = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 0, resolution_type: "failure")
    step.update!(resolution_type: "")

    assert_equal "success", step.reload.resolution_type
  end

  test "a new Escalate step is medium priority until told otherwise" do
    step = Steps::Escalate.create!(workflow: @workflow, title: "Escalate", position: 0)

    assert_equal "medium", step.reload.priority
  end

  test "a blank priority is read as medium" do
    step = Steps::Escalate.create!(workflow: @workflow, title: "Escalate", position: 0, priority: "high")
    step.update!(priority: nil)

    assert_equal "medium", step.reload.priority
  end

  test "an explicit value is kept" do
    step = Steps::Escalate.create!(workflow: @workflow, title: "Escalate", position: 0, priority: "urgent")

    assert_equal "urgent", step.reload.priority
  end
end
