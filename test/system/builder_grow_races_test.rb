require "application_system_test_case"

# The builder's races: two things landing on one step close together - this
# author's own autosave and their grow, their save and another editor's write,
# their response and somebody else's broadcast. Split from builder_grow_test.rb,
# which holds the ordinary path.
#
# Where a test has NO wait between two actions, the gap is the race. Do not add
# one (see AGENTS.md § Testing).
class BuilderGrowRacesTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "grow-race-sys-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in_as @user
  end

  # System tests commit their records, so a user made here outlives the test.
  teardown do
    User.where("email LIKE ?", "grow-race-sys-%").destroy_all
  end

  # What builder_grow_test.rb's "growing inside the autosave window…" used to
  # prove, by a road that is still open. Since a
  # grow waits for the panel's pending save (step-list#growAfterPendingSave),
  # this author's own grow can no longer land ahead of their own flush - so
  # that test passes even if TransitionSync goes back to deleting everything.
  # An edge written by SOMEONE ELSE while this panel sits open still can: a
  # health Fix, another editor's grow. The panel's next save carries a snapshot
  # taken before that edge existed, and must leave it alone.
  #
  # Mutation check: make TransitionSync#call start its transaction with
  # `@step.transitions.destroy_all`. This test must fail on the last assertion.
  test "a connection written elsewhere while the panel is open survives the panel's next save" do
    question = Steps::Question.create!(workflow: @workflow, title: "Untitled Question", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    Transition.create!(step: question, target_step: target, condition: "light == 'no'", label: "No")

    within("turbo-frame#builder-panel") { fill_in "step[title]", with: "Is the light green?" }

    assert_eventually(timeout: 10) { question.reload.title == "Is the light green?" }
    assert_equal ["light == 'no'"], question.transitions.reload.map(&:condition)
  end

  # The panel's doors are rendered by the server, so for the two seconds after
  # the answer type changes they still show the step as it WAS: a Text question's
  # single "Next". Pressed then, the grow used to land first and write that
  # door's blank-condition edge; the flush behind it then made the step Yes/No,
  # and the edge caught both answers with nobody having looked at No.
  #
  # NO wait between choosing the type and pressing the door - that gap is the
  # race. The grow now waits for the pending save, and the server refuses a door
  # the step no longer has.
  test "a door pressed before the answer-type save lands does not write a catch-all connection" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "text", variable_name: "light")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      find(".choice-card", text: "Yes / No").click
      find(".step-doors__row", text: "Next").click_on "New step"
    end
    pick_type "Action"

    assert_eventually(timeout: 10) { question.reload.answer_type == "yes_no" }
    assert_text "answers have changed", wait: 10
    assert_empty question.transitions.reload, "a connection was written from a door the step no longer has"
    assert_equal 1, @workflow.steps.reload.count

    # And the panel now offers the doors the step really has.
    within "turbo-frame#builder-panel" do
      assert_selector ".step-doors__row", text: "Yes", wait: 5
      assert_selector ".step-doors__row", text: "No"
    end
  end

  # The same race through the other button. "Use existing…" names a door the
  # same way a stub does, so a pick made inside the autosave debounce used to
  # land ahead of the save and point the OLD door - a Text question's single
  # "Next" - at a step; the save behind it then made the question Yes/No, and
  # that blank-condition connection caught both answers.
  #
  # NO wait between choosing the type and picking: that gap is the race.
  test "a target picked before the answer-type save lands does not write a catch-all connection" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "text", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "All done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    within "turbo-frame#builder-panel" do
      find(".choice-card", text: "Yes / No").click
      find(".step-doors__row", text: "Next").click_on "Use existing…"
    end
    within("dialog[open]") { click_on target.title }

    assert_eventually(timeout: 10) { question.reload.answer_type == "yes_no" }

    # Wait for the pick to have ANSWERED, either way - a connection written, or
    # the refusal in the dialog - so the assertion below cannot pass merely
    # because nothing has happened yet.
    assert_eventually(timeout: 10) do
      question.transitions.reload.any? ||
        page.has_css?("dialog[open] .form-error", text: /answers have changed/, wait: 0)
    end
    assert_empty question.transitions, "a connection was written from a door the step no longer has"
  end

  # flush() is what a grow waits on, so it must not report "nothing in flight"
  # while a save is. Turbo dispatches turbo:submit-end from a `finally`, so a
  # submission ABORTED because a newer save superseded it fires one too - with
  # no `success` key in its detail, since it never got a result. Counting that
  # as the end let a grow through while the save that mattered was still on its
  # way: type a title, then change the answer type, then press a door.
  #
  # Driven through the controller, not the network: a system test cannot hold
  # one save in flight while a second supersedes it. The event shapes are
  # Turbo's own (FormSubmission#requestFinished, turbo-rails 2.0.23).
  test "a superseded save's aborted submit-end does not end what flush is waiting for" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    open_step(question)

    states = page.evaluate_script(<<~JS)
      (() => {
        const form = document.querySelector('#builder-panel form[data-controller~="inline-autosave"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(form, "inline-autosave")
        controller.trackSubmission()
        controller.trackSubmission() // a second save supersedes the first
        form.dispatchEvent(new CustomEvent("turbo:submit-end", { bubbles: true, detail: { formSubmission: {} } }))
        const afterAbort = controller.inFlight !== null && controller.inFlight !== undefined
        form.dispatchEvent(new CustomEvent("turbo:submit-end", { bubbles: true, detail: { formSubmission: {}, success: true } }))
        const afterSuccess = controller.inFlight !== null && controller.inFlight !== undefined
        return [afterAbort, afterSuccess]
      })()
    JS

    assert_equal [true, false], states, "[still in flight after the aborted one, still in flight after the real one]"
  end

  # A list broadcast is rendered from a read taken when it is sent. One that
  # another editor's request rendered BEFORE this author's grow committed can
  # reach this browser AFTER the grow's own response has rendered - and for that
  # moment the new step has no row, so syncSelectedRow closes its panel (it must:
  # a panel on a step with no row is what a DELETED step looks like, and its
  # autosave would 404 the whole page). The next list render has the row again,
  # and the panel used to stay closed. It reopens now, unless the author has
  # opened something else meanwhile.
  #
  # Injected streams, not two real overlapping requests: see the note on
  # "a grown step's selection survives…" in workflow_builder_test.rb.
  test "a panel closed by a stale list render reopens when the row comes back" do
    first = Steps::Action.create!(workflow: @workflow, title: "First", position: 1)
    grown = Steps::Action.create!(workflow: @workflow, title: "Just grown", position: 2)
    Transition.create!(step: first, target_step: grown)
    @workflow.update!(start_step: first)
    visit workflow_path(@workflow, edit: true)
    open_step(grown)

    render_list_stream(@workflow.steps.where.not(id: grown.id))
    assert_no_selector "turbo-frame#builder-panel form", wait: 5

    render_list_stream(@workflow.steps)
    assert_selector "turbo-frame#builder-panel .builder__panel-body[data-step-id='#{grown.id}']", wait: 5
    assert_selector "#{STEP_ROW}[data-step-id='#{grown.id}'].builder__step--selected", wait: 5
  end

  test "a panel closed by a stale list render stays closed once the author has opened another" do
    first = Steps::Action.create!(workflow: @workflow, title: "First", position: 1)
    grown = Steps::Action.create!(workflow: @workflow, title: "Just grown", position: 2)
    Transition.create!(step: first, target_step: grown)
    @workflow.update!(start_step: first)
    visit workflow_path(@workflow, edit: true)
    open_step(grown)

    render_list_stream(@workflow.steps.where.not(id: grown.id))
    assert_no_selector "turbo-frame#builder-panel form", wait: 5
    open_step(first)

    render_list_stream(@workflow.steps)
    assert_selector "#{STEP_ROW}[data-step-id='#{grown.id}']", wait: 5
    assert_selector "turbo-frame#builder-panel .builder__panel-body[data-step-id='#{first.id}']"
    assert_no_selector "turbo-frame#builder-panel .builder__panel-body[data-step-id='#{grown.id}']"
  end

  private

  def pick_type(name)
    within(".builder__type-picker") { find(".builder__type-name", text: name, exact_text: true).click }
  end

  # The same stream broadcast_step_list sends, rendered straight into the page.
  def render_list_stream(steps)
    html = ApplicationController.render(
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: steps.ordered.includes(transitions: :target_step) }
    )
    stream = %(<turbo-stream action="update" target="steps-list"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(#{stream.to_json})")
  end
end
