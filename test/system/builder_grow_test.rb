require "application_system_test_case"

# Building a small branching workflow the way an author does it: from the step
# they are on, without the Health panel and without binding a step to another in
# a <select>. If the No answer ever needs Health to attach it, this project was
# not implemented.
class BuilderGrowTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    @user = User.create!(email: "grow-sys-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in_as @user
  end

  # System tests commit their records, so a user made here outlives the test.
  teardown do
    User.where("email LIKE ?", "grow-sys-%").destroy_all
  end

  test "a branching flow grows from its rows" do
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5

    click_on "Add unconnected step"
    pick_type "Question"
    assert_selector STEP_ROW, count: 1
    assert_selector "input[name='step[answer_type]'][value='yes_no']:checked", visible: :all, wait: 5
    # Every grow opens the new step's panel, and the list narrows as it slides
    # in - so a stub pressed now moves out from under the click. This is
    # open_step's wait without open_step's click: the panel is already ours.
    assert_panel_settled

    question = @workflow.steps.reload.sole
    within(row(question)) { click_on "No → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2
    assert_panel_settled

    action = @workflow.steps.reload.find_by!(type: "Steps::Action")
    edge = question.transitions.reload.sole
    assert_equal [action.id, "No", "untitled_question == 'no'"], [edge.target_step_id, edge.label, edge.condition]
    assert_operator action.position, :>, question.position

    # The panel is open on the new Action; the Question's Yes stub is still on its row.
    within(row(question)) { assert_selector ".builder__door-stub", text: "Yes → add step" }

    within(row(action)) { click_on "→ add step" }
    pick_type "Resolve"
    assert_selector STEP_ROW, count: 3
    assert_equal 1, action.transitions.reload.count
    assert_nil action.transitions.first.condition

    assert_no_selector ".builder__door-stub", text: "No →"
  end

  # The autosave race. Changing the answer type marks the panel dirty for two
  # seconds; growing replaces the panel, and the closing panel flushes a save
  # that carries its snapshot of this step's connections - a snapshot taken
  # before the grow. That save used to delete every connection and rebuild from
  # the snapshot, taking the new edge with it.
  #
  # The Question starts as Yes/No so the No door is on screen when the panel
  # opens, and the panel is dirtied through the TITLE: changing the answer type
  # would not do, because the No door it creates is server-rendered and only
  # appears once that autosave has landed - by which time the panel is clean
  # and its closing flush sends nothing.
  test "growing inside the autosave window keeps the new connection" do
    question = Steps::Question.create!(workflow: @workflow, title: "Untitled Question", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: "Is the light green?"
      find(".step-doors__row", text: "No").click_on "New step"
    end
    pick_type "Action"

    assert_selector STEP_ROW, count: 2
    # The title arriving proves the closing panel's flush was sent. Without this
    # the test passes whenever no flush fires, which is the hollow version.
    assert_eventually(timeout: 10) { question.reload.title == "Is the light green?" }
    assert_equal ["light == 'no'"], question.transitions.reload.map(&:condition)
  end

  # Task B2. Panel A (another tab, or another editor's save landing behind
  # this one) deletes an extra connection this panel was rendered with. This
  # panel's next save must not bring it back: the row was in `rendered`, never
  # `minted`, so TransitionSync skips it and heals the panel instead of
  # re-creating it. The "Other connections" disclosure renders `open` only
  # when it has rows (see _transitions_editor.html.erb), so asserting it
  # closed afterwards - rather than clicking its summary, which would close
  # an already-open one and prove nothing - is itself proof the row is gone
  # from the editor, not just the database.
  test "a connection removed elsewhere is not brought back by this panel's next save" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Action.create!(workflow: @workflow, title: "Somewhere else", position: 2)
    extra = Transition.create!(step: question, target_step: target, condition: "tier == 'gold'")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    connections = "##{dom_id(question, :connections)}"
    within connections do
      assert_selector "details.step-disclosure[open]", text: "Other connections"
      assert_selector ".transition-item", count: 1
    end

    # Bypasses the controller (and its broadcast) on purpose: this is what a
    # second tab's or a health-fix's own save looks like from here, landing
    # with no signal that reaches this open panel.
    Transition.find(extra.id).destroy

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: "Renamed while stale"
    end

    assert_selector "#flash .flash--notice", text: /removed elsewhere/, wait: 10
    assert_eventually(timeout: 10) { question.reload.title == "Renamed while stale" }
    assert_not transition_exists?(uuid: extra.uuid)

    within connections do
      assert_no_selector "details.step-disclosure[open]"
      assert_selector "summary", text: /Other connections.*numeric ranges, other variables/m
    end
  end

  # Task B2. Continues the scenario above: once the panel has healed, a
  # further save must not flash again and must not resurrect anything. The
  # flash auto-dismisses after 5s on its own timer - waiting on that would
  # make the "no flash" assertion pass whenever it simply hadn't fired yet, so
  # this closes the first notice itself and proves the second save happened
  # from the database, not from the timer.
  test "after a heal, this panel's next save does not flash again and does not resurrect anything" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Action.create!(workflow: @workflow, title: "Somewhere else", position: 2)
    extra = Transition.create!(step: question, target_step: target, condition: "tier == 'gold'")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    Transition.find(extra.id).destroy

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: "Renamed while stale"
    end

    assert_selector "#flash .flash--notice", text: /removed elsewhere/, wait: 10
    assert_eventually(timeout: 10) { question.reload.title == "Renamed while stale" }

    find("#flash .flash__close").click
    assert_no_selector "#flash .flash--notice", wait: 5

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: "Second edit after heal"
    end

    assert_eventually(timeout: 10) { question.reload.title == "Second edit after heal" }
    assert_no_selector "#flash .flash--notice"
    assert_not transition_exists?(uuid: extra.uuid)
  end

  # Task B2. `minted` is what makes a row this panel added and saved still
  # deletable in the SAME panel session - the delete-set job `known` used to
  # do alone. The new row's condition compares the step's own variable with
  # "!=", which Step::Doors never claims for any door (a door only ever
  # matches an "==" comparison - see Step::Doors#reads_as?), so it stays an
  # "extra" the whole way through and neither save here replaces the editor
  # wholesale - proving this is the client's own `minted` bookkeeping at work,
  # not the server re-rendering a fresh `rendered` list that happens to still
  # contain the row.
  test "a connection added and saved in this panel can still be removed in it" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"
      # The target goes LAST. A row with no target is written nowhere, so no
      # autosave landing between these four selects can save a half-built
      # connection. Target first, and a debounce firing before the condition
      # was chosen would save a blank-condition edge - which is the "Anything
      # else" door, so the row would move out of the editor mid-sequence.
      find("select[data-condition-preset-target='presetDropdown']").select "Custom..."
      find("select[data-condition-preset-target='sentenceOperator']").select "is not"
      find("[data-condition-preset-target='sentenceValue'] select").select "Yes"
      find("select[data-transition-field='target_uuid']").select "Done"
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    edge = question.transitions.sole
    assert_equal [target.id, "light != 'yes'"], [edge.target_step_id, edge.condition]

    hidden_value = find("input[name='step[transitions_json]']", visible: false).value
    state = JSON.parse(hidden_value)
    assert_includes state["minted"], edge.uuid
    assert_not_includes state["rendered"], edge.uuid

    within "turbo-frame#builder-panel" do
      find(".transition-item__delete").click
    end

    assert_eventually(timeout: 10) { !transition_exists?(id: edge.id) }
  end

  # Holds the Ruby doors and the JS presets together by what they do, not by
  # reading one from the other's source.
  test "a connection made with the editor's No preset is read as the No door" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"
      find("select[data-transition-field='target_uuid']").select "Done"
      find("select[data-condition-preset-target='presetDropdown']").select "No"
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    no_door = Step::Doors.for(question.reload).doors.find { |door| door.label == "No" }
    assert_equal target, no_door.target_step

    within "turbo-frame#builder-panel" do
      assert_selector ".step-doors__row", text: /No.*Done/m, wait: 5
    end
  end

  # Finding 1. A Yes/No Question has its No door wired. Switching the answer
  # type to Text means Step::Doors no longer claims that edge - it becomes an
  # extra - and the fix is that the whole connections fragment streams back,
  # not just the (now empty) doors list, so "Other connections" shows it at
  # once instead of only after the panel is closed and reopened.
  test "switching answer type reveals a former door in Other connections" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    Transition.create!(step: question, target_step: target, condition: "light == 'no'", label: "No")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      find(".choice-card", text: "Text Input").click
      assert_selector "summary", text: /Other connections.*1 connection/m, wait: 5
      label_input = find(".transition-item__label", wait: 5)
      assert_equal "No", label_input.value
    end
  end

  test "a door can be pointed at a step that already exists, and Back does not bring the dialog with it" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    done = Steps::Resolve.create!(workflow: @workflow, title: "All done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Use existing…")
    within "dialog[open]" do
      fill_in "Find a step", with: "done"
      click_on "All done"
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    edge = question.transitions.sole
    assert_equal [done.id, "light == 'yes'"], [edge.target_step_id, edge.condition]
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes.*All done/m }
    assert_no_selector "dialog[open]", visible: :all
  end

  # Finding 1, the server path. The dialog's candidate list is rendered with
  # the panel and not touched again until a connection is made from THIS
  # step, so a step destroyed after the dialog opened - directly, the way a
  # request from another tab or another editor would land, with no broadcast
  # reaching this page - still shows its (now stale) option. Picking it used
  # to raise ActiveRecord::RecordNotFound uncaught: the dialog's form has no
  # data-turbo-frame and sits inside #builder-panel, so Turbo read the
  # resulting 404 HTML page as that FRAME's own response and wiped the panel
  # to "Content missing". The fix answers inside the still-open dialog
  # instead, the way any other refusal does.
  test "picking a step the server has already lost answers inside the dialog, not Content missing" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    gone = Steps::Resolve.create!(workflow: @workflow, title: "About to vanish", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Use existing…")
    within("dialog[open]") { assert_selector ".step-target-list__option", text: "About to vanish", wait: 5 }

    # Bypasses the controller (and so its broadcast) on purpose: this is what
    # the dialog's own stale copy looks like, not what a live collaborator's
    # delete looks like (that path is finding 3, covered elsewhere).
    Step.find(gone.id).destroy

    within("dialog[open]") { click_on "About to vanish" }

    assert_selector "turbo-frame#builder-panel form", wait: 5
    assert_selector "dialog[open]", wait: 5
    within("dialog[open]") do
      assert_selector ".form-error", text: /no longer in this workflow/i, wait: 5
    end
    assert_no_text "Content missing"
    assert_equal 0, question.transitions.reload.count
  end

  # Finding 3. steps/_target_picker is only re-rendered by a connection made
  # from THIS step (see AGENTS.md), so deleting a DIFFERENT step while this
  # panel stays open never reaches this dialog's own candidate list - it
  # would otherwise keep offering a step that no longer exists until the
  # panel is closed and reopened. The list still updates by the ordinary
  # route (a broadcast repaints the row list), so
  # step_target_picker#markGoneOptions can tell a live step from a gone one
  # by checking the builder's own rows, fresh, every time the dialog opens.
  test "deleting another step while a panel is open removes it from that panel's Use existing list" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    other = Steps::Action.create!(workflow: @workflow, title: "Power cycle the modem", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    other_row = row(other)
    other_row.hover
    accept_confirm { other_row.find("button[title='Remove step']").click }
    assert_no_selector "#{STEP_ROW}[data-step-uuid='#{other.uuid}']", wait: 5

    open_target_picker("Yes", "Use existing…")
    within("dialog[open]") do
      assert_no_selector ".step-target-list__option", text: "Power cycle the modem"
      fill_in "Find a step", with: "power"
      assert_selector ".form-hint", text: "No step matches.", visible: true
    end
  end

  # The test above only shows the dialog closes on a successful submit - by
  # then it is already closed, so leaving and coming back would prove nothing
  # about the turbo:before-cache handler. This leaves the dialog OPEN instead,
  # then leaves the page: that is the moment Turbo caches this page's DOM (the
  # dialog still in it) for a future Back, and the handler's one chance to
  # close it before the snapshot is taken.
  #
  # A modal blocks every click on the page behind it (Selenium refuses to
  # click a nav link here: the dialog "would receive the click"), so a real
  # user could only leave through browser chrome - typing a URL, a bookmark,
  # the physical Back button - never a page link. `Turbo.visit` stands in for
  # that: a real Turbo Drive visit, executed in the page rather than clicked.
  # `history.back()` runs in the page for the same reason AND on purpose,
  # matching test/system/admin_users_test.rb's proven pattern: Capybara's own
  # `go_back` travels through WebDriver, and on that path Chrome closes the
  # modal itself - so the assertion below would still pass with the
  # turbo:before-cache handler removed.
  test "Back does not bring an open target-picker dialog back with it" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Use existing…")

    execute_script("Turbo.visit(#{workflows_path.to_json})")
    assert_selector "h1", text: "Workflows", wait: 5

    execute_script("history.back()")
    assert_selector "turbo-frame#builder-panel form", wait: 5

    assert_no_selector "dialog[open]", visible: :all
  end

  # builder_controller closes the whole panel on Escape, with no awareness of a
  # modal dialog on top of it. The dialog must swallow the keypress before that
  # listener sees it, or picking a target and changing your mind loses the
  # panel you were editing along with the dialog.
  test "Escape closes the dialog without also closing the panel behind it" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Use existing…")

    find("[data-step-target-picker-target='filter']").send_keys(:escape)

    assert_no_selector "dialog[open]", visible: :all
    assert_selector "turbo-frame#builder-panel form", wait: 5
  end

  test "Change retargets a wired door's own edge instead of adding a second one" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    first_target = Steps::Resolve.create!(workflow: @workflow, title: "First", position: 2)
    second_target = Steps::Resolve.create!(workflow: @workflow, title: "Second", position: 3)
    edge = Transition.create!(step: question, target_step: first_target, condition: "light == 'yes'", label: "Yes")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Change")
    within "dialog[open]" do
      fill_in "Find a step", with: "second"
      click_on "Second"
    end

    assert_eventually(timeout: 10) { edge.reload.target_step_id == second_target.id }
    assert_equal 1, question.transitions.reload.count
    assert_equal edge.id, question.transitions.sole.id
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes.*Second/m }
    assert_no_selector "dialog[open]", visible: :all
  end

  # showModal() promotes the dialog (and its ::backdrop) to the browser's top
  # layer; #flash is a fixed-position element in the ordinary stacking context
  # and renders behind it regardless of z-index. So a refusal has to answer
  # inside the dialog too, or the author sees nothing at all.
  test "a refused Change answers inside the still-open dialog, and a later success clears it" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    first = Steps::Resolve.create!(workflow: @workflow, title: "First", position: 2)
    second = Steps::Action.create!(workflow: @workflow, title: "Second branch", position: 3)
    third = Steps::Resolve.create!(workflow: @workflow, title: "Third target", position: 4)
    edge = Transition.create!(step: question, target_step: first, condition: "light == 'yes'", label: "Yes")
    # An extra sharing the Yes door's own condition: retargeting the door onto
    # its target collides with it.
    Transition.create!(step: question, target_step: second, condition: "light == 'yes'")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Change")
    within "dialog[open]" do
      fill_in "Find a step", with: "second"
      click_on "Second branch"
    end

    # The refusal has to travel before the dialog can be judged: without this
    # wait, `within "dialog[open]"` below could match the dialog as it was a
    # moment ago and then fail on an error element the stream had not filled
    # in yet. Naming the wait says which fact the test is waiting for.
    assert_selector "dialog[open]", wait: 5
    within "dialog[open]" do
      assert_selector ".form-error", text: /already has a transition/i, wait: 5
    end
    assert_equal first.id, edge.reload.target_step_id
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes.*First/m }

    within "dialog[open]" do
      fill_in "Find a step", with: "third"
      click_on "Third target"
    end

    assert_eventually(timeout: 10) { edge.reload.target_step_id == third.id }
    assert_no_selector "dialog[open]", visible: :all
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes.*Third target/m }

    open_target_picker("Yes", "Change")
    within "dialog[open]" do
      assert_no_selector ".form-error", text: /already has a transition/i
    end
  end

  # A pick refused because its step is gone re-streams the candidate list
  # fresh, and the filter used to run only when the dialog opened - so the
  # text the author had typed sat above a list it no longer described.
  test "a refused pick keeps the typed filter applied to the fresh list" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    Steps::Resolve.create!(workflow: @workflow, title: "First", position: 2)
    doomed = Steps::Action.create!(workflow: @workflow, title: "Second branch", position: 3)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    open_target_picker("Yes", "Use existing…")
    within "dialog[open]" do
      fill_in "Find a step", with: "second"
      assert_no_selector ".step-target-list__option", text: "First"
    end

    # Gone behind this browser's back: its row is still in the list here, so
    # nothing on the page knows until the pick is refused.
    doomed.destroy!

    within("dialog[open]") { click_on "Second branch" }

    within "dialog[open]" do
      assert_selector ".form-error", text: /./, wait: 5
      assert_no_selector ".step-target-list__option", text: "Second branch"
      assert_no_selector ".step-target-list__option", text: "First"
      assert_text "No step matches."
    end
  end

  # Deleting a step used to leave the rows that pointed at it stale until
  # reload: the parent kept showing the dead target and no stub. destroy now
  # answers the way a grow does - the whole list replaced - so this proves it
  # without a reload.
  test "deleting a grown step returns its parent's door to a stub" do
    visit workflow_path(@workflow, edit: true)
    click_on "Add unconnected step"
    pick_type "Question"
    assert_panel_settled

    question = @workflow.steps.reload.sole
    within(row(question)) { click_on "No → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2
    assert_panel_settled

    action = @workflow.steps.reload.find_by!(type: "Steps::Action")
    within(row(question)) { assert_no_selector ".builder__door-stub", text: "No →" }

    action_row = row(action)
    action_row.hover
    accept_confirm { action_row.find("button[title='Remove step']").click }

    assert_no_selector "#{STEP_ROW}[data-step-uuid='#{action.uuid}']", wait: 5
    within(row(question)) { assert_selector ".builder__door-stub", text: "No → add step", wait: 5 }
  end

  # Finding 4. Deleting the step whose OWN panel is open used to leave that
  # panel open on a step that no longer exists: its autosave form targets
  # _top, so its next PATCH 404'd the whole page.
  # builder_controller#syncSelectedRow - which already runs after every
  # stream render to decide which row is selected - now closes the panel
  # when the open step has no row left. Asserted after a few seconds so a
  # genuinely-quiet dangling autosave (see AGENTS.md and
  # test/system/builder_grow_test.rb browser QA notes for the pending-save
  # case, checked by hand against the dev server - a system test dirtying
  # the title and racing a delete against the 2s debounce is itself flaky)
  # would have had time to misbehave if it were going to.
  test "deleting the open step's own row closes the panel without navigating away" do
    visit workflow_path(@workflow, edit: true)
    click_on "Add unconnected step"
    pick_type "Question"
    assert_panel_settled

    question = @workflow.steps.reload.sole
    within(row(question)) { click_on "No → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2
    assert_panel_settled

    action = @workflow.steps.reload.find_by!(type: "Steps::Action")
    # The panel opens on the new Action after that grow; switch it to the
    # Question instead, so the list is NOT empty once the Question is gone
    # (the Action row survives) - destroy_streams only clears the panel
    # itself when the whole list is empty, so closing it here is this fix's
    # job alone, not the server's existing empty-list branch.
    open_step(question)

    question_row = row(question)
    question_row.hover
    accept_confirm { question_row.find("button[title='Remove step']").click }

    assert_no_selector "turbo-frame#builder-panel form", wait: 5
    assert_no_selector "#{STEP_ROW}[data-step-uuid='#{question.uuid}']"
    assert_selector "#{STEP_ROW}[data-step-uuid='#{action.uuid}']"

    sleep 3
    assert_selector ".builder__list", visible: true
    assert_no_selector ".flash--alert"
    assert_no_text "Content missing"
  end

  # Every grow leaves the panel open, which narrows the list to 38% - exactly
  # where a two-stub row's title used to wrap inside its own shrunk box and
  # visually run under the stub buttons. The stubs now take their own line
  # instead, so the title's own line boxes and the stubs' box never intersect,
  # and a row with nothing to wrap (Resolve, no doors) stays one line tall.
  test "a stubbed row's title does not overlap its stubs while the panel is open" do
    visit workflow_path(@workflow, edit: true)
    click_on "Add unconnected step"
    pick_type "Question"
    assert_panel_settled

    question = @workflow.steps.reload.sole
    within(row(question)) { assert_selector ".builder__door-stub", count: 2 }
    assert_not overlapping_title_and_doors?(question), "the title overlaps the stubs with two doors open"

    within(row(question)) { click_on "Yes → add step" }
    pick_type "Resolve"
    assert_selector STEP_ROW, count: 2
    assert_panel_settled

    resolve = @workflow.steps.reload.find_by!(type: "Steps::Resolve")
    within(row(question)) { assert_selector ".builder__door-stub", count: 1 }
    assert_not overlapping_title_and_doors?(question), "the title overlaps the stub with one door open"

    # The Resolve row has no doors to wrap and must stay the single-line
    # height a stubbed row no longer is.
    assert_operator row_height(question), :>, row_height(resolve) + 10
  end

  # A dropdown option containing an apostrophe used to write a condition the
  # runner could never take (AGENTS.md's old "known limit" for Step::Doors).
  # Growing from this door proves the whole path end to end: the stored
  # condition, the door reading as wired, and a run answering the option
  # landing on the grown step - not just Doors agreeing with itself.
  test "growing from an apostrophe door writes a condition the runner takes" do
    question = Steps::Question.create!(workflow: @workflow, title: "What blinks?", question: "What blinks?",
                                       position: 1, answer_type: "dropdown", variable_name: "light",
                                       options: [{ "label" => "Don't know", "value" => "Don't know" },
                                                 { "label" => "Router", "value" => "router" }])
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within(row(question)) { click_on "Don't know → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2
    assert_panel_settled

    action = @workflow.steps.reload.find_by!(type: "Steps::Action")
    edge = question.transitions.reload.sole
    assert_equal 1, edge.condition.count("\\")
    assert_equal [action.id, "light == 'Don\\'t know'"], [edge.target_step_id, edge.condition]

    door = Step::Doors.for(question.reload).doors.find { |d| d.label == "Don't know" }
    assert_not door.stub?
    assert_equal action, door.target_step

    next_step = StepResolver.new(@workflow).resolve_next(question.reload, { "light" => "Don't know" })
    assert_equal action, next_step
  end

  # With that edge present a second time (a hand-made duplicate, so
  # Step::Doors reports it as an extra rather than the door itself), the
  # "Other connections" editor must read the SAME condition text back to its
  # option preset - not fall to Custom because a JS-side comparison stayed
  # byte-for-byte. The `<details>` already renders open (extras.any?), so
  # this asserts inside it rather than clicking the summary, which would
  # close it.
  test "an extra duplicate of an apostrophe door's edge restores to its option preset" do
    question = Steps::Question.create!(workflow: @workflow, title: "What blinks?", question: "What blinks?",
                                       position: 1, answer_type: "dropdown", variable_name: "light",
                                       options: [{ "label" => "Don't know", "value" => "Don't know" },
                                                 { "label" => "Router", "value" => "router" }])
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    other_target = Steps::Action.create!(workflow: @workflow, title: "Somewhere else", position: 3)
    condition = Step::Doors.for(question).doors.find { |d| d.label == "Don't know" }.condition

    Transition.create!(step: question, target_step: target, condition: condition, label: "Don't know", position: 0)
    Transition.create!(step: question, target_step: other_target, condition: condition, position: 1)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      assert_selector "summary", text: /Other connections.*1 connection/m, wait: 5
      assert_selector ".transition-item select[data-condition-preset-target='presetDropdown'] option[value='option_0']:checked",
                      wait: 5
    end
  end

  # The panel's own JS preset and a stored condition can now be escaped two
  # different ways for the same backslash-carrying value - the OLD writer
  # never escaped it (one backslash), the NEW writer does (two). This extra
  # is the OLD style; the door's own edge (position 0, not shown here) is
  # the NEW style. condition_preset_controller#conditionsMatch has to parse
  # both sides and accept either reading, or this row would drop to Custom.
  test "an extra duplicate whose backslash is escaped the old way still restores to its option preset" do
    question = Steps::Question.create!(workflow: @workflow, title: "Which drive?", question: "Which drive?",
                                       position: 1, answer_type: "dropdown", variable_name: "path",
                                       options: [{ "label" => "C Drive", "value" => 'C:\temp' },
                                                 { "label" => "Router", "value" => "router" }])
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    other_target = Steps::Action.create!(workflow: @workflow, title: "Somewhere else", position: 3)
    new_style = Step::Doors.for(question).doors.find { |d| d.label == "C Drive" }.condition
    assert_equal 2, new_style.count("\\")
    old_style = "path == 'C:\\temp'"
    assert_equal 1, old_style.count("\\")

    Transition.create!(step: question, target_step: target, condition: new_style, label: "C Drive", position: 0)
    Transition.create!(step: question, target_step: other_target, condition: old_style, position: 1)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      assert_selector "summary", text: /Other connections.*1 connection/m, wait: 5
      assert_selector ".transition-item select[data-condition-preset-target='presetDropdown'] option[value='option_0']:checked",
                      wait: 5
    end
  end

  # The three tests above all pin what a condition_preset_controller#escapeQuotes
  # change looks like when it works; none of them writes a fresh edge through
  # the browser's own escaping and checks what actually lands in the
  # database. This does - the same pattern as "a connection made with the
  # editor's No preset is read as the No door" above, but for a value that
  # needs escaping. If escapeQuotes ever reverted to quotes-only, this is the
  # test that would catch it: the stored condition would carry one backslash
  # instead of two and the runner check below would fail.
  test "a connection made through the editor's own preset writes the escaped condition the runner takes" do
    question = Steps::Question.create!(workflow: @workflow, title: "Which drive?", question: "Which drive?",
                                       position: 1, answer_type: "dropdown", variable_name: "path",
                                       options: [{ "label" => "C Drive", "value" => 'C:\temp' },
                                                 { "label" => "Router", "value" => "router" }])
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"
      find("select[data-transition-field='target_uuid']").select "Done"
      find("select[data-condition-preset-target='presetDropdown']").select "C Drive"
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    edge = question.transitions.sole
    assert_equal 2, edge.condition.count("\\")
    assert ConditionEvaluator.evaluate(edge.condition, { "path" => 'C:\temp' })

    door = Step::Doors.for(question.reload).doors.find { |d| d.label == "C Drive" }
    assert_equal target, door.target_step
  end

  private

  # The app server and this test share one connection, and a request switches
  # its query cache on - so a plain Transition.exists? polled right after a
  # save can keep answering from before that save. See
  # test/system/admin_group_folders_test.rb's #saved_order for the same trap.
  def transition_exists?(**attrs)
    Transition.uncached { Transition.exists?(**attrs) }
  end

  def row(step)
    find("#{STEP_ROW}[data-step-uuid='#{step.uuid}']")
  end

  def row_rects(step)
    page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector("#{STEP_ROW}[data-step-uuid='#{step.uuid}']");
        const title = row.querySelector('.list-row__title');
        const doors = row.querySelector('.builder__step-doors');
        const titleLines = title
          ? Array.from(title.getClientRects()).map(r => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom }))
          : [];
        const d = doors ? doors.getBoundingClientRect() : null;
        return {
          titleLines,
          doorsRect: d ? { left: d.left, top: d.top, right: d.right, bottom: d.bottom } : null
        };
      })()
    JS
  end

  # Compares every line box of the title (a wrapped, overflowing title
  # generates more than one - see the rect docs above) against the stubs'
  # single box, rather than the title element's own outer rect, which can
  # report a shrunk layout width even while its text visually overflows it.
  def overlapping_title_and_doors?(step)
    rects = row_rects(step)
    doors_rect = rects["doorsRect"]
    return false unless doors_rect

    rects["titleLines"].any? do |line|
      !(line["right"] <= doors_rect["left"] || doors_rect["right"] <= line["left"] ||
        line["bottom"] <= doors_rect["top"] || doors_rect["bottom"] <= line["top"])
    end
  end

  def row_height(step)
    page.evaluate_script(
      "document.querySelector(\"#{STEP_ROW}[data-step-uuid='#{step.uuid}']\").getBoundingClientRect().height"
    )
  end

  def pick_type(name)
    within(".builder__type-picker") { find(".builder__type-name", text: name, exact_text: true).click }
  end

  # Clicks a door row's button ("Use existing…" or "Change") and waits for
  # the target-picker dialog it opens - the one interaction every test in
  # this file that touches the dialog shares, so they can't drift into
  # slightly different (and differently racy) open sequences.
  def open_target_picker(row_text, button_text)
    within "turbo-frame#builder-panel" do
      find(".step-doors__row", text: row_text).click_on button_text
    end
    assert_selector "dialog[open]", wait: 5
  end
end
