require "application_system_test_case"

# Two editors, one step. The panel submits the whole step on every change, so
# before this they clobbered each other even on fields neither was sharing.
#
# "Someone else" here is a direct UPDATE rather than a second browser: what the
# server does with a second writer is the thing under test, and a real second
# session would make these tests slower without making them stricter. The
# refusal case asserts the losing editor's own text is still on their screen,
# which is the half a direct UPDATE cannot fake.
class BuilderFieldScopedTest < ApplicationSystemTestCase
  setup do
    @editor = User.create!(
      email: "field-sys-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Two Editors WF", user: @editor, status: "draft")
    @step = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Original title",
      question: "Original question?", variable_name: "q1", answer_type: "text"
    )
    @workflow.update!(start_step: @step)
    sign_in_as @editor
  end

  # The case the whole design exists for, and the one a lock_version
  # implementation would have failed.
  test "one editor renaming the title does not undo another editor's question text" do
    visit_builder_in_edit_mode
    open_step(@step)

    # Someone else saves the question text while this panel sits open.
    Step.where(id: @step.id).update_all(question: "Theirs, saved elsewhere")

    fill_in "step[title]", with: "Mine"
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    @step.reload
    assert_equal "Mine", @step.title
    assert_equal "Theirs, saved elsewhere", @step.question,
                 "the untouched question must survive this panel's save"
  end

  test "editing a field someone else changed is refused with the typing left in place" do
    visit_builder_in_edit_mode
    open_step(@step)

    Step.where(id: @step.id).update_all(title: "Theirs, saved elsewhere")

    fill_in "step[title]", with: "Mine"
    assert_selector "[data-autosave-status]", text: "Not saved", wait: 10
    assert_selector "#flash", text: /someone else changed/i

    assert_equal "Mine", find("input[name='step[title]']").value,
                 "the refused text must still be in the field"
    assert_equal "Theirs, saved elsewhere", @step.reload.title
  end

  # The phantom-conflict case: this author's own second edit must not be refused
  # against the value their own first edit replaced.
  test "a second edit by the same author saves" do
    visit_builder_in_edit_mode
    open_step(@step)

    fill_in "step[title]", with: "First"
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    fill_in "step[title]", with: "Second"
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    assert_equal "Second", @step.reload.title
  end

  private

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end
end
