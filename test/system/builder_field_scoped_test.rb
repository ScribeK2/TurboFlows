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

  # The refusal tells the author to change it again to save over theirs. That
  # promise was false until the server started naming the conflicting field:
  # nothing updated the panel's baseline, so the second attempt was refused
  # against a value the database had left behind and the author was stuck until
  # they reloaded. A browser found it; the refusal test above never tried to
  # recover.
  test "an author who is refused can save over the other editor on the next try" do
    visit_builder_in_edit_mode
    open_step(@step)

    Step.where(id: @step.id).update_all(title: "Theirs, saved elsewhere")

    fill_in "step[title]", with: "Mine, first try"
    assert_selector "[data-autosave-status]", text: "Not saved", wait: 10

    fill_in "step[title]", with: "Mine, second try"
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    assert_equal "Mine, second try", @step.reload.title
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

  # Lexxy does not fire the input events markDirty listens for, and its editor
  # is form-associated, so a lookup that failed would silently stop rich text
  # saving altogether — worse than the clobbering this all replaces.
  test "a rich text edit is marked dirty and saves" do
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Do the thing")
    Transition.create!(step: @step, target_step: action, position: 0)

    visit_builder_in_edit_mode
    open_step(action)

    find("lexxy-editor").click
    send_keys("Typed instructions")
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    assert_includes action.reload.instructions.body.to_html, "Typed instructions"
  end

  # The phantom-conflict case again, for rich text, whose baseline is a
  # server-rendered hidden input rather than the input's own value. Nothing
  # moved it after a save, so every second save of Instructions in one panel
  # opening was refused as "someone else changed instructions" with nobody
  # else there - reported from prod by a lone author on a draft (2026-09-23).
  test "a second rich text edit by the same author saves" do
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Do the thing")
    Transition.create!(step: @step, target_step: action, position: 0)

    visit_builder_in_edit_mode
    open_step(action)

    find("lexxy-editor").click
    send_keys("First words")
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    send_keys(" and more")
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10
    assert_no_selector "#flash", text: /someone else changed/i

    assert_includes action.reload.instructions.body.to_html, "First words and more"
  end

  # The other half of the fix above: the baseline follows the SERVER after this
  # author's save, so a real second writer after it is still caught.
  test "a rich text edit someone else overwrote after this author's save is refused" do
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Do the thing")
    Transition.create!(step: @step, target_step: action, position: 0)

    visit_builder_in_edit_mode
    open_step(action)

    find("lexxy-editor").click
    send_keys("First words")
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    action.reload.update!(instructions: "<p>Theirs, saved elsewhere</p>")

    send_keys(" and more")
    assert_selector "[data-autosave-status]", text: "Not saved", wait: 10
    assert_selector "#flash", text: /someone else changed instructions/i
    assert_includes action.reload.instructions.body.to_html, "Theirs, saved elsewhere"
  end

  # The baseline for rich text is server-rendered, so an empty body must not
  # conflict with the editor's own "<p><br></p>" reading of it.
  test "a rich text field with an empty body saves on the first edit" do
    message = Steps::Message.create!(workflow: @workflow, position: 2, title: "Say hello")
    assert_predicate message.content.to_s, :blank?

    visit_builder_in_edit_mode
    open_step(message)

    find("lexxy-editor").click
    send_keys("First words")
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    assert_includes message.reload.content.body.to_html, "First words"
  end

  # The rich-text baseline is a full copy of the body, and the server only reads
  # it for a field that is dirty. Editing something else must not carry it.
  test "a rich text baseline is not submitted when that field was not edited" do
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Do the thing")
    action.update!(instructions: "<p>Existing body</p>")
    Transition.create!(step: @step, target_step: action, position: 0)

    visit_builder_in_edit_mode
    open_step(action)

    fill_in "step[title]", with: "Renamed only"
    assert_selector "[data-autosave-status]", text: "Saved", wait: 10

    assert page.evaluate_script(
      "document.querySelector('input[data-autosave-rendered][name=\\'step[rendered][instructions]\\']').disabled"
    ), "an untouched rich-text baseline must not be submitted"
    assert_equal "Renamed only", action.reload.title
    assert_includes action.instructions.body.to_html, "Existing body"
  end

  private

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end
end
