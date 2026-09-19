require "application_system_test_case"

# Where the keyboard lands. Every transition here used to drop focus on the
# document body: the element that had it was removed by a Turbo Stream, and
# nothing said where to go next - so a keyboard user was returned to the top of
# the page after every pick, grow and dismissal.
#
# These assert document.activeElement, which is a fact a browser can settle.
# What they do NOT settle is whether a screen reader ANNOUNCES the live regions
# below; see the note on the empty-alert test.
class BuilderFocusTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "wf-system-test-a11y-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Focus", user: @user, status: "draft")
    @question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                        position: 1, answer_type: "yes_no", variable_name: "light")
    @target = Steps::Resolve.create!(workflow: @workflow, title: "All done", position: 2)
    @workflow.update!(start_step: @question)
    sign_in_as @user
  end

  test "dismissing the target picker returns focus to the button that opened it" do
    visit workflow_path(@workflow, edit: true)
    open_step(@question)
    assert_panel_settled

    open_picker_for("Yes")
    assert_equal "Find a step", active_label, "the dialog did not focus its filter"

    page.driver.browser.action.send_keys(:escape).perform

    assert_no_selector "dialog[open]", visible: :all, wait: 5
    assert_equal "Use an existing step for “Yes”", active_label
  end

  test "picking a target leaves focus in the panel, not on the document" do
    visit workflow_path(@workflow, edit: true)
    open_step(@question)
    assert_panel_settled

    open_picker_for("Yes")
    within("dialog[open]") { click_on @target.title }

    assert_eventually(timeout: 10) { @question.transitions.reload.any? }
    assert_no_selector "dialog[open]", visible: :all, wait: 5
    assert_equal "step-doors", page.evaluate_script("document.activeElement?.className"),
                 "focus fell out of the panel after a successful pick"
  end

  test "growing a step focuses the new step's title" do
    visit workflow_path(@workflow, edit: true)
    open_step(@question)
    assert_panel_settled

    within("turbo-frame#builder-panel") do
      find(".step-doors__row", text: "No").click_on "New step"
    end
    within(".builder__type-picker") { find(".builder__type-name", text: "Action", exact_text: true).click }

    assert_eventually(timeout: 10) { @workflow.steps.reload.count == 3 }
    assert_equal "step[title]", page.evaluate_script("document.activeElement?.name"),
                 "the grown step's panel did not take focus"
    # Selected, not merely focused: the field holds "Untitled Action", and
    # typing should replace it rather than append to it.
    assert_equal "Untitled Action", page.evaluate_script(<<~JS)
      (() => {
        const el = document.activeElement
        return el.value.slice(el.selectionStart, el.selectionEnd)
      })()
    JS
  end

  # The mechanism a live region depends on: it has to be IN the accessibility
  # tree before its text arrives. `display: none` takes it out, so an alert
  # that is revealed and filled in the same breath is the unreliable case.
  # Empty and present costs no space, since an empty block has no line box.
  #
  # This proves presence and zero cost, NOT that any given screen reader
  # speaks - that needs a real one, and this suite cannot be it.
  test "the dialog's error region is present and costs nothing while empty" do
    visit workflow_path(@workflow, edit: true)
    open_step(@question)
    assert_panel_settled
    open_picker_for("Yes")

    box = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("dialog[open] .form-error")
        const cs = getComputedStyle(el)
        return { display: cs.display, height: el.getBoundingClientRect().height, text: el.textContent.trim() }
      })()
    JS

    assert_equal "", box["text"]
    assert_not_equal "none", box["display"], "an empty alert region is out of the accessibility tree"
    assert_equal 0, box["height"].to_i, "an empty alert region reserves space"
  end

  private

  def open_picker_for(door_label)
    within("turbo-frame#builder-panel") do
      find(".step-doors__row", text: door_label).click_on "Use existing…"
    end
    assert_selector "dialog[open]", wait: 5
  end

  # The accessible name of whatever has focus: aria-label, else the associated
  # label's text, else the element's own text.
  def active_label
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.activeElement
        if (!el || el === document.body) return "(document body)"
        return el.getAttribute("aria-label")
          || (el.labels && el.labels[0]?.textContent.trim())
          || el.textContent.trim()
      })()
    JS
  end
end
