require "test_helper"

# "Last edited" is the later of the workflow row and its newest step, because a
# step edit never touches the workflow (Step belongs_to :workflow has a counter
# cache and no touch:). Spec: docs/designs/2026-09-12-editor-admin-home.md.
class WorkflowRecentlyEditedTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "recent-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")
    @mine = Workflow.where(user: @user)
  end

  test "a step edited after its workflow outranks a workflow renamed more recently than that workflow" do
    renamed = workflow("Renamed", edited_at: 2.days.ago)
    stepped = workflow("Stepped", edited_at: 5.days.ago, step_edited_at: 1.day.ago)

    result = Workflow.recently_edited(@mine, limit: 2)

    assert_equal [stepped, renamed], result.map(&:first)
    assert_in_delta 1.day.ago.to_f, result.first.last.to_f, 5
  end

  test "a workflow renamed after its last step edit uses the rename" do
    renamed = workflow("Renamed today", edited_at: 1.hour.ago, step_edited_at: 3.days.ago)
    stepped = workflow("Stepped yesterday", edited_at: 5.days.ago, step_edited_at: 1.day.ago)

    assert_equal [renamed, stepped], Workflow.recently_edited(@mine, limit: 2).map(&:first)
  end

  # The union of "top N by row" and "top N by newest step" must contain the true
  # top N. Here the newest edit is on a workflow whose own row is the oldest.
  test "finds a workflow that is newest only by its step, beyond the top rows" do
    newest_row = workflow("Row 1h", edited_at: 1.hour.ago)
    workflow("Row 2h", edited_at: 2.hours.ago)
    workflow("Row 3h", edited_at: 3.hours.ago)
    old_row_new_step = workflow("Old row, new step", edited_at: 10.days.ago, step_edited_at: 30.minutes.ago)

    assert_equal [old_row_new_step, newest_row], Workflow.recently_edited(@mine, limit: 2).map(&:first)
  end

  test "keeps to the scope it is given" do
    mine = workflow("Mine", edited_at: 2.days.ago)
    other = User.create!(email: "recent-other-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")
    Workflow.create!(title: "Theirs", user: other, status: "draft")

    assert_equal [mine], Workflow.recently_edited(@mine, limit: 5).map(&:first)
  end

  test "an empty scope returns nothing" do
    assert_equal [], Workflow.recently_edited(@mine, limit: 5)
  end

  private

  def workflow(title, edited_at:, step_edited_at: nil)
    record = Workflow.create!(title:, user: @user, status: "draft")
    if step_edited_at
      step = Steps::Resolve.create!(workflow: record, position: 0, title: "Done", resolution_type: "success")
      step.update_columns(updated_at: step_edited_at)
    end
    record.update_columns(updated_at: edited_at)
    record
  end
end
