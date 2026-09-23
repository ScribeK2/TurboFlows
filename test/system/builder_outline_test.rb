require "application_system_test_case"

# The step list is an outline of the graph. These drive it the way an author
# does and read the page.
class BuilderOutlineTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    @user = User.create!(email: "outline-sys-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in_as @user
  end

  teardown do
    User.where("email LIKE ?", "outline-sys-%").destroy_all
  end

  # Closing the panel re-widens .builder__list over the same 250ms transition
  # that widens the panel on open (see assert_panel_settled in
  # application_system_test_case.rb) - .builder__list-tools, which holds
  # Collapse all/Expand all, slides with it (justify-content: flex-end). A
  # click sent mid-animation lands where the button used to be, missing it
  # silently: no exception, just a click nothing was under. Poll the tools
  # row's own position until two consecutive reads agree.
  def assert_list_settled(timeout: 5)
    deadline = Time.current + timeout
    previous = nil
    loop do
      right_edge = page.evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector(".builder__list-tools");
          return el ? Math.round(el.getBoundingClientRect().right) : null;
        })()
      JS
      return if right_edge && right_edge == previous

      flunk "the list never settled after closing the panel (#{right_edge.inspect})" if Time.current > deadline
      previous = right_edge
      sleep 0.1
    end
  end

  # Yes → Working, No → Power cycle → Did it come back? (Yes → Working, No → Escalate)
  def toy_graph
    @q1 = Steps::Question.create!(workflow: @workflow, title: "Power light green?", position: 0, answer_type: "yes_no", variable_name: "light")
    @working = Steps::Resolve.create!(workflow: @workflow, title: "Working", position: 1)
    @cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 2)
    @q2 = Steps::Question.create!(workflow: @workflow, title: "Did it come back?", position: 3, answer_type: "yes_no", variable_name: "back")
    @escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to tier 2", position: 4)
    Transition.create!(step: @q1, target_step: @working, condition: "light == 'yes'", position: 0)
    Transition.create!(step: @q1, target_step: @cycle, condition: "light == 'no'", position: 1)
    Transition.create!(step: @cycle, target_step: @q2)
    Transition.create!(step: @q2, target_step: @working, condition: "back == 'yes'", position: 0)
    Transition.create!(step: @q2, target_step: @escalate, condition: "back == 'no'", position: 1)
    @workflow.update_columns(start_step_id: @q1.id)
  end

  test "the step I add after No sits after the question, and Yes stays a stub on it" do
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5

    click_on "Add unconnected step"
    pick_type "Question"
    assert_selector STEP_ROW, count: 1
    assert_panel_settled
    fill_in "step[title]", with: "Power light green?"
    question = @workflow.steps.reload.first

    within(node_for(question)) { click_on "No → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2, wait: 5
    assert_panel_settled

    action = @workflow.steps.reload.find_by(type: "Steps::Action")
    assert_selector "#steps-list[role='tree']"
    assert_selector "#{STEP_NODE}[data-node-uuid='#{question.uuid}'] + #{STEP_NODE}[data-node-uuid='#{action.uuid}']"
    within(node_for(question)) { assert_selector ".builder__door-stub", text: "Yes → add step" }
    assert_equal "1", node_for(question)["aria-level"]
    assert_equal "1", node_for(action)["aria-level"]
  end

  test "a merged step renders once; the other door is a jump that names it and opens it" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    within(node_for(@q1)) do
      assert_selector ".builder__outline-jump", text: "Yes → Working · step 4"
      assert_no_text "below"
    end
    within(node_for(@q2)) { assert_selector "#{STEP_NODE}[data-node-uuid='#{@working.uuid}']" }
    assert_equal "2", node_for(@working)["aria-level"]

    within(node_for(@q1)) { find(".builder__outline-jump").click }
    assert_selector "turbo-frame#builder-panel form", wait: 5
    assert_panel_settled
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']"
    assert_selector "#{STEP_ROW}[data-step-uuid='#{@working.uuid}'].builder__step--selected"
    assert_no_selector ".builder__outline-jump.builder__step--selected"
    assert_equal "true", node_for(@working)["aria-selected"]
  end

  test "a merged step says how many ways lead in, and names them" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    ways = find("##{dom_id(@working, :ways_in)}")
    assert_equal "2 ways in", ways.text.strip
    assert_equal "From step 1 · Yes, step 3 · Yes", ways[:title]
    assert_includes node_for(@working)["aria-labelledby"], dom_id(@working, :ways_in)
    assert_no_selector "##{dom_id(@cycle, :ways_in)}"
  end

  test "a renamed step's jump chip follows the rename" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    open_step(@working)
    fill_in "step[title]", with: "All working"
    within(node_for(@q1)) { assert_selector ".builder__outline-jump", text: /All working/, wait: 5 }
    # The open panel survived the list re-render.
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']"
  end

  test "view mode reads the stubs and offers no buttons" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: q, target_step: done, condition: "q == 'no'", position: 0)
    @workflow.update_columns(start_step_id: q.id)

    visit workflow_path(@workflow)
    assert_selector "[data-builder-mode-value='view']", wait: 5
    within(node_for(q)) do
      assert_selector ".builder__door-stub-text", text: "→ nothing yet"
      assert_no_selector ".builder__door-stub", visible: true
    end
  end

  test "steps nothing leads to sit in Unconnected" do
    a = Steps::Action.create!(workflow: @workflow, title: "A", position: 0)
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    lone = Steps::Resolve.create!(workflow: @workflow, title: "Lone", position: 2)
    Transition.create!(step: a, target_step: done)
    @workflow.update_columns(start_step_id: a.id)

    visit workflow_path(@workflow, edit: true)
    # The section heading is text-transform: uppercase, and Capybara reads
    # the rendered text.
    assert_selector ".builder__outline-section", text: /unconnected/i, wait: 5
    assert_selector ".builder__outline-section + #{STEP_NODE}[data-node-uuid='#{lone.uuid}']"
  end

  test "a folded branch stays folded across a re-render, and says what is inside" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    fold_selector = "details[data-fold-key='#{@q2.uuid}:Yes']"
    assert find(fold_selector)[:open], "folds start open"
    find("#{fold_selector} > summary").click
    assert_no_selector "#{fold_selector}[open]"
    # The label must read the closed fold from a single manual click, not
    # only from a toggleAll() call - a trusted click's activation behaviour
    # (the browser flipping `open`) runs AFTER the click event's own
    # listeners, so a label computed inside the click handler would still be
    # reading the state being left.
    assert_button "Expand all"
    within(fold_selector) { assert_selector ".builder__outline-fold-count", text: "→ Working · step 4 · 1 step" }

    open_step(@q1)
    fill_in "step[title]", with: "Power light green?!"
    assert_selector "#{STEP_ROW}[data-step-title='Power light green?!']", wait: 5
    # "the re-render kept the fold"
    assert_no_selector "#{fold_selector}[open]"
  end

  test "a fold survives a whole-list replace from a delete" do
    toy_graph
    lone = Steps::Resolve.create!(workflow: @workflow, title: "Lone", position: 9)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 6, wait: 5

    find("details[data-fold-key='#{@q2.uuid}:Yes'] > summary").click
    assert_selector "details[data-fold-key='#{@q2.uuid}:Yes']:not([open])"
    # #destroy also broadcasts an update("steps-list") that lands over the
    # cable before the HTTP response's replace("step-list"), and that update
    # only swaps #steps-list's CHILDREN - it would leave a wrongly mounted
    # controller and its dataset probe alone. Only the real whole-list replace
    # swaps #step-list itself, taking the probe with it, so waiting for the
    # probe to vanish is what actually waits for the mutation this test means
    # to exercise.
    execute_script("document.getElementById('step-list').dataset.probe = 'old'")
    # .builder__step-delete is opacity: 0 until the row is hovered, so it must
    # be hovered before Capybara/Selenium will treat it as clickable.
    row = find("#{STEP_ROW}[data-step-uuid='#{lone.uuid}']")
    row.hover
    accept_confirm { row.find(".builder__step-delete").click }
    assert_no_selector "#step-list[data-probe]", wait: 5
    # Working's own row is a legitimate zero: the fold hiding it is exactly
    # what this test is proving survived, so count what exists, not what's
    # currently on screen.
    assert_selector STEP_ROW, count: 5, wait: 5, visible: :all
    assert_selector "details[data-fold-key='#{@q2.uuid}:Yes']:not([open])"
  end

  test "a folded branch reveals the step whose panel is open" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    find("details[data-fold-key='#{@q2.uuid}:Yes'] > summary").click
    within(node_for(@q1)) { find(".builder__outline-jump").click }
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']", wait: 5
    assert_selector "details[data-fold-key='#{@q2.uuid}:Yes'][open]", wait: 5
  end

  test "Collapse all closes every fold, and Expand all opens them, across a re-render" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    click_on "Collapse all"
    assert_no_selector "details[data-fold-key][open]"
    assert_button "Expand all"

    open_step(@q1)
    fill_in "step[title]", with: "Renamed"
    assert_selector "#{STEP_ROW}[data-step-title='Renamed']", wait: 5
    assert_no_selector "details[data-fold-key][open]"

    find("#builder-panel button[title='Close panel']").click
    assert_list_settled
    click_on "Expand all"
    assert_selector "details[data-fold-key][open]"
    assert_button "Collapse all"
  end

  test "view mode folds too" do
    toy_graph
    visit workflow_path(@workflow)
    assert_selector "[data-builder-mode-value='view']", wait: 5
    assert_button "Collapse all"
    find("details[data-fold-key='#{@q2.uuid}:Yes'] > summary").click
    assert_no_selector "details[data-fold-key='#{@q2.uuid}:Yes'][open]"
  end

  test "no folds, no Collapse all" do
    a = Steps::Action.create!(workflow: @workflow, title: "A", position: 0)
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: a, target_step: done)
    @workflow.update_columns(start_step_id: a.id)

    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 2, wait: 5
    assert_no_button "Collapse all"
    assert_no_button "Expand all"
  end

  def pick_existing_from(step, door_text)
    within(node_for(step)) { click_on door_text }
    within(".builder__type-picker") { click_on "An existing step…" }
    assert_selector "dialog#list-target-picker[open]", wait: 5
  end

  test "an unwired answer wires to an existing step from its chip, and the panel is left alone" do
    toy_graph
    Transition.where(step: @q2, condition: "back == 'no'").delete_all # No on step "Did it come back?" is now a stub
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    open_step(@cycle)

    pick_existing_from(@q2, "No → add step")
    within("dialog#list-target-picker") do
      assert_no_selector "li[data-step-id='#{@q2.id}']:not(.is-hidden)", text: "Did it come back?"
      fill_in "Find a step", with: "Escalate"
      click_on "Escalate to tier 2"
    end

    assert_no_selector "dialog#list-target-picker[open]", wait: 5
    assert_equal @escalate, @q2.transitions.reload.find_by(condition: "back == 'no'").target_step
    within(node_for(@q2)) { assert_no_selector ".builder__door-stub", text: "No → add step" }
    # The open panel is untouched.
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@cycle.id}']"
  end

  test "wiring from the chip with the same step's panel open keeps its door rows in step" do
    toy_graph
    Transition.where(step: @q2, condition: "back == 'no'").delete_all
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    open_step(@q2)

    pick_existing_from(@q2, "No → add step")
    within("dialog#list-target-picker") { click_on "Escalate to tier 2" }
    assert_selector "#builder-panel .step-doors", text: /No.*Escalate to tier 2/m, wait: 5
  end

  test "a refused pick answers inside the dialog, and picking another works" do
    toy_graph
    Transition.where(step: @q2, condition: "back == 'no'").delete_all
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    pick_existing_from(@q2, "No → add step")
    @escalate.destroy # a collaborator deleted it while the dialog was open
    within("dialog#list-target-picker") { click_on "Escalate to tier 2" }
    within("dialog#list-target-picker") do
      assert_selector "#list-target-picker-error", text: "no longer in this workflow", wait: 5
      assert_no_selector "button", text: "Escalate to tier 2"
      click_on "Working"
    end
    assert_no_selector "dialog#list-target-picker[open]", wait: 5
    assert_equal @working, @q2.transitions.reload.find_by(condition: "back == 'no'").target_step
  end

  test "the list dialog offers a step grown after the page loaded" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 1, wait: 5

    within(node_for(q)) { click_on "No → add step" }
    pick_type "Resolve"
    assert_selector STEP_ROW, count: 2, wait: 5
    assert_panel_settled
    grown = @workflow.steps.reload.find_by(type: "Steps::Resolve")

    pick_existing_from(q, "Yes → add step")
    within("dialog#list-target-picker") { assert_selector "li[data-step-id='#{grown.id}']" }
  end

  # This tab's own grow answers with the WHOLE #step-list, dialog included, so
  # the test above passes whether or not anything refreshes the dialog. A step
  # grown in another tab arrives only as the list broadcast, which replaces
  # #steps-list's children and not the dialog beside them - that is the case
  # broadcast_step_list's companion #list-target-picker-options exists for.
  test "the list dialog offers a step grown in another tab" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 1, wait: 5

    using_session(:second_tab) do
      sign_in_as @user
      visit workflow_path(@workflow, edit: true)
      assert_selector STEP_ROW, count: 1, wait: 5
      within(node_for(q)) { click_on "No → add step" }
      pick_type "Resolve"
      assert_selector STEP_ROW, count: 2, wait: 5
    end
    grown = @workflow.steps.reload.find_by(type: "Steps::Resolve")

    assert_selector STEP_ROW, count: 2, wait: 10
    pick_existing_from(q, "Yes → add step")
    within("dialog#list-target-picker") { assert_selector "li[data-step-id='#{grown.id}']" }
  end

  test "the existing-step item appears only for a list chip" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 1, wait: 5

    # Shown for a chip first, so the bottom prompt has to hide it again.
    within(node_for(q)) { click_on "No → add step" }
    within(".builder__type-picker") { assert_button "An existing step…" }
    find("body").send_keys(:escape)
    assert_no_selector ".builder__type-picker:not([hidden])"

    click_on "Add unconnected step"
    within(".builder__type-picker") { assert_no_button "An existing step…" }
    find("body").send_keys(:escape)

    open_step(q)
    within("#builder-panel .step-doors") { find("[data-grow-from]", match: :first).click }
    within(".builder__type-picker") { assert_no_button "An existing step…" }
  end

  test "a quoted answer label wires from its chip and returns focus to it" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "multiple_choice", variable_name: "q",
                                options: [{ "label" => %(Won't "turn on"), "value" => "wont" }, { "label" => "Fine", "value" => "fine" }])
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: q, target_step: done, condition: "q == 'fine'", position: 0)
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 2, wait: 5

    pick_existing_from(q, %(Won't "turn on" → add step))
    within("dialog#list-target-picker") { click_on "Done" }
    assert_no_selector "dialog#list-target-picker[open]", wait: 5
    within(node_for(q)) { assert_selector ".builder__outline-jump", text: "→ Done · step 2" }
    # Focus lands a frame after the list re-renders (focusWhenReplaced), so the
    # jump can be on the page a moment before it holds focus.
    assert_eventually { page.evaluate_script("document.activeElement.classList.contains('builder__outline-jump')") }
  end
end
