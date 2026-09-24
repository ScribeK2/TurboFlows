require "application_system_test_case"

# The step panel's controls, exercised the way an author uses them. Each of the
# behaviours here was found broken in the 2026-09-15 audit: the value saved but
# the control never showed it, or the control showed it and nothing saved.
class BuilderStepPanelTest < ApplicationSystemTestCase
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

  # The panel autosaves and said nothing at all, which is how a refused save
  # went unnoticed for months (see TODOS "The step panel has no save
  # indicator"). Four states, and the dirty one matters as much as the rest:
  # while the 2s debounce runs, an indicator still reading "Saved" is a lie.
  test "the panel says when an edit is unsaved, saving, and saved" do
    action = Steps::Action.create!(workflow: @workflow, title: "Check the router", position: 1)
    visit_builder_in_edit_mode
    open_step action
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_selector "[data-autosave-status]", text: "Saved", wait: 5
      fill_in "step[title]", with: "Check the modem"
      assert_selector "[data-autosave-status]", text: "Unsaved changes", wait: 2
      assert_selector "[data-autosave-status]", text: "Saved", wait: 10
    end

    assert_equal "Check the modem", action.reload.title
  end

  # The header named the step as it was when the panel OPENED, so renaming one
  # left it reading "Untitled Question" above a field that said otherwise.
  #
  # It follows the field as you type rather than waiting for the save: the
  # indicator beside it already says whether what you are looking at is stored,
  # so live text here is not a claim that it is.
  test "the panel header follows the title as it is typed, before the save lands" do
    action = Steps::Action.create!(workflow: @workflow, title: "Check the router", position: 1)
    visit_builder_in_edit_mode
    open_step action
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_selector ".builder__panel-header-left strong", text: "Check the router"
      fill_in "step[title]", with: "Check the modem"

      # Both at once: the header has caught up while the edit is still unsaved.
      assert_selector "[data-autosave-status]", text: "Unsaved changes"
      assert_selector ".builder__panel-header-left strong", text: "Check the modem"
    end
  end

  test "emptying the title leaves the header saying Untitled, not blank" do
    action = Steps::Action.create!(workflow: @workflow, title: "Check the router", position: 1)
    visit_builder_in_edit_mode
    open_step action
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: ""
      assert_selector ".builder__panel-header-left strong", text: "Untitled"
    end
  end

  # A save the server refuses. The reason goes to #flash as it always did; what
  # was missing is the panel itself admitting the edit is not saved.
  test "the panel says Not saved when the server refuses the edit" do
    action = Steps::Action.create!(workflow: @workflow, title: "Check the router", position: 1)
    visit_builder_in_edit_mode
    open_step action
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      find("summary", text: "Guidance").click
      fill_in "step[reference_url]", with: "javascript:alert(1)"
      assert_selector "[data-autosave-status]", text: "Not saved", wait: 10
    end

    within("#flash") { assert_text(/must use http/i, wait: 5) }
    assert_nil action.reload.reference_url
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

    click_on "Add unconnected step"
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

  # An option label with no spaces (a ticket id, a URL) never wrapped: the
  # door row's label was flex: 0 0 auto, so it pushed "→ target", Change and
  # Remove off the panel and grew a horizontal scrollbar (QA B-003).
  #
  # Mutation check: put `.step-doors__label` back to `flex: 0 0 auto` with no
  # overflow-wrap - red.
  test "a long unbroken answer label wraps inside its door row" do
    long = "L" * 200
    question = Steps::Question.create!(workflow: @workflow, title: "Pick one", question: "Pick one", position: 1,
                                       answer_type: "multiple_choice", variable_name: "pick",
                                       options: [{ "label" => long, "value" => "long" }, { "label" => "Short", "value" => "short" }])
    Transition.create!(step: question, target_step: @resolve, condition: "pick == 'long'", position: 0)
    visit_builder_in_edit_mode
    open_step question

    row = find(".step-doors__row", text: "L" * 20)
    widths = page.evaluate_script(<<~JS)
      (() => { const row = document.querySelectorAll(".step-doors__row")[0];
               const panel = document.querySelector(".builder__panel").getBoundingClientRect();
               const buttons = [...row.querySelectorAll("button")].map(b => Math.round(b.getBoundingClientRect().right));
               return { scroll: row.scrollWidth, client: row.clientWidth, panelRight: Math.round(panel.right), buttons } })()
    JS
    assert row
    assert_operator widths["scroll"], :<=, widths["client"], "the door row scrolls sideways: #{widths.inspect}"
    widths["buttons"].each { |right| assert_operator right, :<=, widths["panelRight"], "a button sits past the panel: #{widths.inspect}" }
  end

  private

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end
end
