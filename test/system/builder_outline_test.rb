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
    # The tree is inside #steps-list, which also holds the empty state.
    assert_selector "#steps-list > [role='tree'][aria-label='Steps']"
    assert_no_selector "#steps-list[role='tree']"
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

  # The panel prints step numbers too - its door rows ("Yes → Working · 4") and
  # its "Use existing…" candidates - and every delete, grow or rewire can
  # renumber the whole outline. The server re-renders only the deleted step's
  # parents' panels, so a panel open on any other step kept the old numbers
  # until it was reopened (QA B-004, 2026-09-23).
  #
  # Mutation check: stop mounting ordinal-sync in _builder.html.erb - red.
  test "an open panel's step numbers follow the list after a delete renumbers it" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    open_step(@q2)
    within("#builder-panel .step-doors") do
      assert_text "Working · 4"
      assert_text "Escalate to tier 2 · 5"
    end

    # Power cycle leads INTO the open step, so the open panel is not one of
    # the deleted step's parents the server re-renders.
    row = find("#{STEP_ROW}[data-step-uuid='#{@cycle.uuid}']")
    row.hover
    accept_confirm { row.find(".builder__step-delete").click }
    assert_selector STEP_ROW, count: 4, wait: 5
    assert_equal "2", find("#{STEP_ROW}[data-step-uuid='#{@working.uuid}'] .builder__step-badge").text.strip

    within("#builder-panel .step-doors") do
      assert_text "Working · 2", wait: 5
      assert_text "Escalate to tier 2 · 4"
    end
    picker_meta = evaluate_script(<<~JS)
      [...document.querySelectorAll("#builder-panel .step-target-list li")]
        .find(li => li.textContent.includes("Working"))?.querySelector(".step-target-list__meta")?.textContent
    JS
    assert_includes picker_meta.to_s, "· 2", "the panel's Use existing… candidates are renumbered too"
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
    # A group labelled by its heading holds the unconnected trees, one level
    # down; the trunk stays outside it.
    group = "[role='tree'] > [role='group'][aria-labelledby='steps-unconnected-heading']"
    assert_selector "#{group} > .builder__outline-section#steps-unconnected-heading"
    assert_selector "#{group} > .builder__outline-section + #{STEP_NODE}[data-node-uuid='#{lone.uuid}']"
    assert_no_selector "#{group} #{STEP_NODE}[data-node-uuid='#{a.uuid}']"
    assert_equal "2", node_for(lone)["aria-level"]
    assert_equal "1", node_for(a)["aria-level"]
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

  # The fold controller's own reveal, with no jump involved: the panel is
  # loaded straight into the frame, so builder#openStep never runs and only
  # outline-fold's "the open step changed" rule can show the branch.
  test "a panel opened without a jump still reveals the hand-folded branch holding its step" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    fold = "details[data-fold-key='#{@q2.uuid}:Yes']"
    find("#{fold} > summary").click
    assert_selector "#{fold}:not([open])"

    execute_script("document.getElementById('builder-panel').src = #{panel_edit_workflow_step_path(@workflow, @working).to_json}")
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']", wait: 5
    assert_selector "#{fold}[open]", wait: 5
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

  # showModal() remembers what had focus and hands it back on close. The type
  # picker's own item is hidden by then, so without putting focus back on the
  # chip first, Escape, Cancel and the backdrop all left focus on <body>.
  test "closing the list dialog without a pick returns focus to the chip" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 1, wait: 5

    pick_existing_from(q, "No → add step")
    find("dialog#list-target-picker").send_keys(:escape)
    assert_no_selector "dialog#list-target-picker[open]", wait: 5
    assert_eventually { page.evaluate_script(chip_focused_js("No")) }

    pick_existing_from(q, "Yes → add step")
    within("dialog#list-target-picker") { click_on "Cancel" }
    assert_no_selector "dialog#list-target-picker[open]", wait: 5
    assert_eventually { page.evaluate_script(chip_focused_js("Yes")) }
  end

  # The acting tab receives its own list broadcast. When it renders after the
  # response it replaces the jump that was just focused. This renders that
  # broadcast late on purpose, the same stream broadcast_step_list sends.
  test "focus survives the pick's own list broadcast arriving after the response" do
    # No (the continuation) leads to Done, so wiring Yes to Done makes Yes a jump.
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: q, target_step: done, condition: "q == 'no'", position: 0)
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 2, wait: 5

    pick_existing_from(q, "Yes → add step")
    within("dialog#list-target-picker") { click_on "Done" }
    within(node_for(q)) { assert_selector ".builder__outline-jump", text: "→ Done" }
    assert_eventually { page.evaluate_script(jump_focused_js) }

    html = ApplicationController.render(
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: @workflow.steps.ordered.includes(transitions: :target_step) }
    )
    stream = %(<turbo-stream action="update" target="steps-list"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(#{stream.to_json})")

    assert_eventually { page.evaluate_script(jump_focused_js) }
  end

  # --- QA fixes, 2026-09-23 ---

  # A chain long enough that .builder__list-scroll scrolls at 1400x900:
  # start → A1 … A20 → Last? (Yes and No both stubs).
  def long_chain
    steps = (1..20).map { |i| Steps::Action.create!(workflow: @workflow, title: "Chain #{i}", position: i) }
    last = Steps::Question.create!(workflow: @workflow, title: "Last?", position: 21, answer_type: "yes_no", variable_name: "last")
    steps.each_cons(2) { |from, to| Transition.create!(step: from, target_step: to) }
    Transition.create!(step: steps.last, target_step: last)
    @workflow.update_columns(start_step_id: steps.first.id)
    [steps, last]
  end

  # Returns the list's scrollTop afterwards, which is 0 when it cannot scroll.
  def scroll_list_to_bottom
    page.evaluate_script("(() => { const s = document.querySelector('.builder__list-scroll'); s.scrollTop = s.scrollHeight; return s.scrollTop })()")
  end

  def row_visible_in_list_js(step)
    <<~JS
      (() => {
        const row = document.querySelector('.builder__step[data-step-id="#{step.id}"]');
        const box = document.querySelector('.builder__list-scroll').getBoundingClientRect();
        if (!row || !row.offsetParent) return false;
        const r = row.getBoundingClientRect();
        return r.top >= box.top - 1 && r.bottom <= box.bottom + 1;
      })()
    JS
  end

  # QA A-007: the grow's response replaces #step-list and its scroller with it,
  # which put the list back at the top with the new row far below.
  test "a grow from a chip low in a long list brings the new row into view" do
    _chain, last = long_chain
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 21, wait: 5
    assert_operator scroll_list_to_bottom, :>, 0, "the list scrolls"

    within(node_for(last)) { click_on "Yes → add step" }
    pick_type "Resolve"
    assert_selector STEP_ROW, count: 22, wait: 5
    grown = @workflow.steps.reload.find_by!(type: "Steps::Resolve")
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{grown.id}']", wait: 5
    assert_panel_settled

    assert_eventually { page.evaluate_script(row_visible_in_list_js(grown)) }
    # The title keeps focus: the scroll takes nothing from it.
    assert_equal "step[title]", page.evaluate_script("document.activeElement?.name")
  end

  # QA C-002: a jump opened its target's panel but left the row off-screen,
  # even when it had just unfolded the branch holding it.
  test "a jump chip scrolls its target's row into view, out of a folded branch" do
    chain, last = long_chain
    q1 = Steps::Question.create!(workflow: @workflow, title: "First?", position: 0, answer_type: "yes_no", variable_name: "first")
    far = Steps::Resolve.create!(workflow: @workflow, title: "Far away", position: 22)
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 23)
    Transition.create!(step: q1, target_step: far, condition: "first == 'yes'", position: 0)
    Transition.create!(step: q1, target_step: chain.first, condition: "first == 'no'", position: 1)
    Transition.create!(step: last, target_step: far, condition: "last == 'yes'", position: 0)
    Transition.create!(step: last, target_step: done, condition: "last == 'no'", position: 1)
    @workflow.update_columns(start_step_id: q1.id)

    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 24, wait: 5
    fold = "details[data-fold-key='#{last.uuid}:Yes']"
    assert_operator scroll_list_to_bottom, :>, 0, "the list scrolls"
    find("#{fold} > summary").click
    assert_selector "#{fold}:not([open])"
    page.execute_script("document.querySelector('.builder__list-scroll').scrollTop = 0")

    within(node_for(q1)) { find(".builder__outline-jump", text: "Far away").click }
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{far.id}']", wait: 5
    assert_selector "#{fold}[open]", wait: 5
    assert_panel_settled
    assert_eventually { page.evaluate_script(row_visible_in_list_js(far)) }
  end

  # Review round 2: View Flow's nodes and the health panel's step links open a
  # step too, and now name it, so its row is selected and scrolled to.
  test "opening a step from View Flow selects its row and brings it into view" do
    _chain, last = long_chain
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 21, wait: 5
    click_on "View Flow"
    find(".flow-diagram__node[title='Last?']", wait: 5).click

    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{last.id}']", wait: 5
    assert_selector "#{STEP_ROW}.builder__step--selected[data-step-uuid='#{last.uuid}']"
    assert_panel_settled
    assert_eventually { page.evaluate_script(row_visible_in_list_js(last)) }
  end

  # QA A-003: one long unbroken run in a title overflowed its row at
  # panel-open width, under the warning icon and Remove.
  test "a long unbroken title wraps inside its row with the panel open" do
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Escalate #{'X' * 90}")
    @workflow.update_columns(start_step_id: step.id)
    visit workflow_path(@workflow, edit: true)
    open_step(step)

    fits = page.evaluate_script(<<~JS)
      [".builder__step .list-row__title", ".builder__step", ".builder__outline"].every(sel => {
        const el = document.querySelector(sel);
        return el.scrollWidth <= el.clientWidth;
      })
    JS
    assert fits, "the title, its row and the outline all fit their width"
  end

  # QA C-001: the open step's branch sprang open again on every keystroke,
  # because the reveal ran on every DOM mutation. It now runs when the open
  # step changes or the list re-renders; between those, the author's fold holds.
  test "folding the open step's branch sticks while typing, and opening another step in it reveals it" do
    toy_graph
    # q2 Yes → Confirm → Working, so the branch holds two steps.
    confirm = Steps::Action.create!(workflow: @workflow, title: "Confirm", position: 5)
    Transition.where(step: @q2, condition: "back == 'yes'").update_all(target_step_id: confirm.id)
    Transition.create!(step: confirm, target_step: @working)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 6, wait: 5
    fold = "details[data-fold-key='#{@q2.uuid}:Yes']"

    open_step(confirm)
    find("#{fold} > summary").click
    assert_selector "#{fold}:not([open])"
    find("#builder-panel input[name='step[title]']").send_keys("!")
    assert_selector "#builder-panel [data-autosave-status]", text: /Unsaved|Saving|Saved/, wait: 5
    sleep 0.3 # a reveal on the keystroke's own mutation lands within a microtask
    assert_selector "#{fold}:not([open])"

    # The title save re-renders the whole list, which reveals the branch again.
    assert_selector "#{STEP_ROW}[data-step-title='Confirm!']", wait: 5, visible: :all
    assert_selector "#{fold}[open]", wait: 5

    # Fold it again and open a different step inside it, from q1's jump.
    find("#{fold} > summary").click
    assert_selector "#{fold}:not([open])"
    within(node_for(@q1)) { find(".builder__outline-jump", text: "Working").click }
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']", wait: 5
    assert_selector "#{fold}[open]", wait: 5
  end

  # Review round 2: a jump to the step whose panel is ALREADY open changes no
  # step, so only the jump's own reveal (builder#openStep asking outline-fold)
  # can show a branch the author folded by hand. A second writer of `open`
  # used to be re-closed by the fold controller's next reapply.
  test "a jump to the already-open step reveals its hand-folded branch" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    fold = "details[data-fold-key='#{@q2.uuid}:Yes']"
    jump = -> { within(node_for(@q1)) { find(".builder__outline-jump", text: "Working").click } }

    jump.call
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']", wait: 5
    assert_panel_settled
    find("#{fold} > summary").click
    assert_selector "#{fold}:not([open])"

    jump.call
    assert_selector "#{fold}[open]", wait: 5
    assert_eventually { page.evaluate_script(row_visible_in_list_js(@working)) }
    sleep 0.5 # the panel reload's own mutations must not re-close it
    assert_selector "#{fold}[open]"
  end

  # QA D-004 (and A-002): when the picked door comes back as plain text (a
  # wired continuation), focus fell back to the row's Remove button, which is
  # opacity 0 until hovered, so the next Space asked "Remove this step?".
  test "a pick that leaves no chip to focus puts focus on the from-step's node, not a Remove button" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    loose = Steps::Resolve.create!(workflow: @workflow, title: "Loose", position: 2)
    Transition.create!(step: q, target_step: done, condition: "q == 'yes'", position: 0)
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 3, wait: 5

    pick_existing_from(q, "No → add step")
    within("dialog#list-target-picker") { click_on "Loose" }
    assert_no_selector "dialog#list-target-picker[open]", wait: 5
    assert_equal loose, q.transitions.reload.find_by(condition: "q == 'no'").target_step

    node_focused = "document.activeElement.matches('[role=treeitem][data-node-uuid=\"#{q.uuid}\"]') && document.activeElement.isConnected"
    assert_eventually { page.evaluate_script(node_focused) }
    assert_not page.evaluate_script("document.activeElement.matches('button')")

    # The pick's own list broadcast, arriving late, replaces the node; the guard
    # puts focus back on the new one, never on a button.
    html = ApplicationController.render(
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: @workflow.steps.ordered.includes(transitions: :target_step) }
    )
    stream = %(<turbo-stream action="update" target="steps-list"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(#{stream.to_json})")
    assert_eventually { page.evaluate_script(node_focused) }
  end

  def jump_focused_js
    "document.activeElement.matches('.builder__outline-jump') && document.activeElement.isConnected"
  end

  def chip_focused_js(label)
    "document.activeElement.matches('.builder__door-stub') && " \
      "document.activeElement.closest('[data-door-key]').dataset.doorKey.endsWith(':#{label}')"
  end
end
