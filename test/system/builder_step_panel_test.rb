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

  # The real path the controller/service tests only simulate: the panel's
  # Connections editor holds a hidden transitions_json snapshot in the SAME
  # autosave form as every other field, taken when the panel opened. Renaming
  # the variable used to have the very next autosave - even one touching an
  # unrelated field - ship that stale snapshot back over the rename.
  test "renaming a question's variable through the panel keeps its own doors renamed" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 1,
                                       question: "Light green?", answer_type: "yes_no",
                                       variable_name: "light_green")
    action = Steps::Action.create!(workflow: @workflow, position: 2, title: "Continue")
    edge = Transition.create!(step: question, target_step: action, condition: "light_green == 'yes'")

    visit_builder_in_edit_mode
    open_step question

    within "turbo-frame#builder-panel" do
      find("summary", text: "Variable name").click
      fill_in "step[variable_name]", with: "verified"
    end
    assert_eventually(timeout: 10) { question.reload.variable_name == "verified" }

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: "Is it verified?"
    end
    assert_eventually(timeout: 10) { question.reload.title == "Is it verified?" }

    assert_equal "verified == 'yes'", edge.reload.condition
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

  test "a new connection lists step titles without their badges and shows Remove" do
    question = Steps::Question.create!(workflow: @workflow, title: "Is the site down?", position: 1,
                                       question: "Is the site down?", answer_type: "yes_no")
    Steps::Escalate.create!(workflow: @workflow, title: "Escalate to network", position: 2)
    visit_builder_in_edit_mode
    assert_selector ".builder__door-stub", text: /add step/
    open_step question

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"
      within all(".transition-item", minimum: 1, wait: 5).last do
        options = all("select[data-transition-field='target_uuid'] option").map { |option| option.text.strip }
        assert_includes options, "Escalate to network"
        assert_includes options, "All done"
        assert_selector "button[title='Remove connection']", visible: true
      end
    end
  end

  test "a guidance note typed in the panel is saved" do
    visit_builder_in_edit_mode
    open_step @resolve

    within "turbo-frame#builder-panel" do
      find("summary", text: "Guidance").click
      fill_in "step[help_text]", with: "Confirm the ticket number back to the caller"
    end
    assert_eventually(timeout: 10) { @resolve.reload.help_text == "Confirm the ticket number back to the caller" }
  end

  test "Escape closes the type picker without closing the panel" do
    visit_builder_in_edit_mode
    open_step @resolve

    click_on "Add a step"
    assert_selector "[data-step-list-target='typePicker']:not([hidden])"

    page.send_keys :escape
    assert_no_selector "[data-step-list-target='typePicker']:not([hidden])"
    assert_selector "turbo-frame#builder-panel form"
  end

  test "the Publish button carries no count badge" do
    Steps::Action.create!(workflow: @workflow, title: "Dangling action", position: 1)
    visit_builder_in_edit_mode

    assert_no_selector ".builder__header-actions .badge, .builder__header-actions [class*='badge']", visible: :all
    assert_selector ".builder__toolbar-issues", text: /error/
  end

  private

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end

  def open_step(step)
    find("#{STEP_ROW}[data-step-uuid='#{step.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5
    assert_panel_settled
  end

  # The panel animates open over 250ms and the fields in it re-wrap as it
  # widens, so a button found mid-animation moves before the click lands and
  # the click hits whatever slid under the old spot. See the identical helper
  # (and its comment) in workflow_builder_test.rb, where this was diagnosed.
  def assert_panel_settled(timeout: 5)
    deadline = Time.current + timeout
    previous = nil
    loop do
      width = panel_body_width
      return if width > 200 && width == previous

      flunk "the panel never settled open (#{width}px wide)" if Time.current > deadline
      previous = width
      sleep 0.1
    end
  end

  def panel_body_width
    page.evaluate_script(<<~JS)
      (() => {
        const b = document.querySelector('#builder-panel .builder__panel-body');
        return b ? Math.round(b.getBoundingClientRect().width) : 0;
      })()
    JS
  end
end
