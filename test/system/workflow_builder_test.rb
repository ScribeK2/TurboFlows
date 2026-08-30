require "application_system_test_case"

# Characterization tests for the unified builder at /workflows/:id.
#
# These replace a set deleted on 2026-08-24 that had rotted onto CSS selectors
# from a builder UI that no longer exists (`.step-item`,
# `button[data-step-type='question']`). Written against semantics instead:
# visible button text, the step list's own `data-step-uuid` hooks, and the
# Turbo Frame id the panel actually uses. Those are behavioural contracts, not
# decoration, so restyling will not silently delete this coverage again.
#
# Every assertion here was mutation-verified when written — the behaviour it
# covers was broken on purpose and the test confirmed to go red — because a
# test written against already-passing code proves nothing until you have seen
# it fail.
class WorkflowBuilderTest < ApplicationSystemTestCase
  # Two elements per step carry data-step-uuid: the row itself and the warning
  # icon, which step_warnings_controller un-hides when the step has issues. A
  # bare [data-step-uuid] therefore counts double for any step with a warning,
  # which makes the count depend on when the async health fetch lands. Scope to
  # the row's list semantics instead.
  STEP_ROW = "[role='listitem'][data-step-uuid]".freeze

  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @workflow = Workflow.create!(title: "Builder E2E Workflow", user: @user, status: "draft")
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "All done", position: 0, resolution_type: "success"
    )
    @workflow.update!(start_step: @resolve)

    sign_in_as @user
  end

  test "adds a step of the type chosen in the picker" do
    visit_builder_in_edit_mode

    assert_step_count 1

    click_on "Add a step"
    click_on "Question"

    assert_step_count 2
    assert_equal 1, @workflow.steps.where(type: "Steps::Question").count
  end

  test "each type in the picker creates that type of step" do
    visit_builder_in_edit_mode

    # The picker offers seven types and every one has to build its own class.
    # A single-type test would not have caught the Form step being missing from
    # the surface area, which has happened before in this codebase.
    {
      "Action" => "Steps::Action",
      "Message" => "Steps::Message",
      "Form" => "Steps::Form",
      "Escalate" => "Steps::Escalate"
    }.each do |label, klass|
      click_on "Add a step"
      click_on label
      assert_selector step_row_selector_for(klass), wait: 5,
                                                    count: 1
    end
  end

  test "removing a step takes its row out of the list" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Doomed step", position: 1,
      question: "Doomed step", answer_type: "yes_no"
    )

    visit_builder_in_edit_mode
    assert_step_count 2
    assert_selector "[role='listitem'][data-step-uuid='#{question.uuid}']"

    # The delete control is opacity:0 until the row is hovered, so hovering is
    # part of the real interaction rather than a test workaround.
    row = step_row(question.uuid)
    row.hover
    accept_confirm { row.find("button[title='Remove step']").click }

    assert_no_selector "[role='listitem'][data-step-uuid='#{question.uuid}']", wait: 5
    assert_step_count 1
  end

  test "clicking a step row opens its editor in the builder panel" do
    visit_builder_in_edit_mode

    # The panel starts as an empty Turbo Frame, so it has no visible content
    # until a step fills it — hence visible: :all on the frame itself.
    assert_selector "turbo-frame#builder-panel", visible: :all
    assert_no_field "step[title]"

    step_row(@resolve.uuid).click

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "All done", wait: 5
    end
  end

  test "editing a step title autosaves and survives a reload" do
    visit_builder_in_edit_mode
    step_row(@resolve.uuid).click

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "All done", wait: 5
      fill_in "step[title]", with: "Renamed by autosave"
    end

    # Autosave is debounced at 2000ms (inline-autosave-delay-value). Polling the
    # record rather than sleeping a flat interval keeps this honest: it fails if
    # the save never lands, instead of passing because the sleep outlasted a
    # broken debounce.
    assert_eventually(timeout: 10) { @resolve.reload.title == "Renamed by autosave" }

    visit workflow_path(@workflow)
    assert_text "Renamed by autosave"
  end

  test "a large workflow renders every step row" do
    # The deleted version of this asserted a 5 second wall-clock budget. That is
    # the kind of timing assertion that fails for reasons unrelated to the code,
    # which is exactly the flakiness this suite was just cleaned of. What is
    # worth protecting is that nothing truncates or paginates the list.
    50.times do |i|
      Steps::Action.create!(
        workflow: @workflow, title: "Bulk step #{i}", position: i + 1,
        action_type: "Instruction"
      )
    end

    visit_builder_in_edit_mode

    assert_step_count 51
    assert_selector STEP_ROW, count: 51, wait: 10
  end

  private

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end

  def step_row(uuid)
    find("[role='listitem'][data-step-uuid='#{uuid}']")
  end

  def assert_step_count(expected)
    assert_selector STEP_ROW, count: expected, wait: 5
  end

  def step_row_selector_for(klass)
    "[data-step-type='#{klass.demodulize.underscore}']"
  end

  # Polls a condition instead of sleeping past a debounce. Returns as soon as
  # the block is true, and fails loudly with the elapsed time if it never is.
  def assert_eventually(timeout: 5, interval: 0.2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "condition never became true within #{timeout}s"
      end
      sleep interval
    end
  end
end
