require "application_system_test_case"

# The step panel's controls, exercised the way an author uses them. Each of the
# behaviours here was found broken in the 2026-09-15 audit: the value saved but
# the control never showed it, or the control showed it and nothing saved.
class BuilderStepPanelTest < ApplicationSystemTestCase
  STEP_ROW = "[role='listitem'][data-step-uuid]".freeze

  setup do
    @user = User.create!(
      email: "wf-system-test-panel-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Panel E2E Workflow", user: @user, status: "draft")
    @resolve = Steps::Resolve.create!(workflow: @workflow, title: "All done", position: 0)
    @workflow.update!(start_step: @resolve)
    sign_in_as @user
  end

  test "choosing an escalation target type shows the choice and saves it" do
    escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to network", position: 1)
    visit_builder_in_edit_mode
    open_step escalate

    within "turbo-frame#builder-panel" do
      choose "Department", allow_label_click: true
      assert_selector "input[name='step[target_type]'][value='department']:checked", visible: :all
      assert_no_selector "input[name='step[target_type]'][value='team']:checked", visible: :all
    end
    assert_eventually(timeout: 10) { escalate.reload.target_type == "department" }
  end

  test "choosing a resolution type moves the choice and refreshes the default description" do
    visit_builder_in_edit_mode
    open_step @resolve

    within "turbo-frame#builder-panel" do
      assert_selector "input[name='step[resolution_type]'][value='success']:checked", visible: :all
      # Case-insensitive: the eyebrow label is styled text-transform: uppercase,
      # and Selenium returns rendered (post-CSS) text.
      assert_text(/Default for Success/i)

      choose "Failure", allow_label_click: true
      assert_selector "input[name='step[resolution_type]'][value='failure']:checked", visible: :all
      assert_no_selector "input[name='step[resolution_type]'][value='success']:checked", visible: :all
      assert_text(/Default for Failure/i, wait: 10)
      assert_text Steps::Resolve::DEFAULT_DESCRIPTIONS["failure"]
    end
    assert_equal "failure", @resolve.reload.resolution_type
  end

  test "changing a question's answer type saves on its own" do
    question = Steps::Question.create!(workflow: @workflow, title: "Is the site down?", position: 1,
                                       question: "Is the site down?", answer_type: "yes_no")
    visit_builder_in_edit_mode
    open_step question

    within "turbo-frame#builder-panel" do
      choose "Number", allow_label_click: true
    end
    assert_eventually(timeout: 10) { question.reload.answer_type == "number" }
  end

  test "cancelling the options warning keeps the answer type and saves nothing" do
    question = Steps::Question.create!(workflow: @workflow, title: "Contact channel?", position: 1,
                                       question: "How did they reach us?", answer_type: "multiple_choice",
                                       options: [{ "label" => "Phone", "value" => "phone" }])
    visit_builder_in_edit_mode
    open_step question
    saved_at = question.reload.updated_at

    within "turbo-frame#builder-panel" do
      dismiss_confirm { choose "Text", allow_label_click: true }
      assert_selector "input[name='step[answer_type]'][value='multiple_choice']:checked", visible: :all
    end
    # Proving "nothing saved" means outlasting the 2s autosave debounce once.
    sleep 3
    assert_equal saved_at, question.reload.updated_at
    assert_equal "multiple_choice", question.answer_type
  end

  test "view mode opens a step as a preview that cannot save" do
    escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to network", position: 1,
                                       target_type: "department", target_value: "Network Ops")
    visit workflow_path(@workflow)
    assert_selector "[data-builder-mode-value='view']", wait: 5
    assert_no_selector "#autosave-status"

    find("#{STEP_ROW}[data-step-uuid='#{escalate.uuid}']").click
    within "turbo-frame#builder-panel" do
      assert_text "Network Ops", wait: 5
      assert_text "Department"
      assert_no_selector "form"
      assert_no_selector "input", visible: :all
    end

    click_on "Details"
    within "turbo-frame#builder-panel" do
      assert_text "Who Can See This", wait: 5
      assert_no_selector "form"
    end
  end

  private

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end

  def open_step(step)
    find("#{STEP_ROW}[data-step-uuid='#{step.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5
  end
end
