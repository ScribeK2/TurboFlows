require "application_system_test_case"

# Two editors on one workflow.
#
# Replaces concurrent_editing_test.rb, deleted 2026-08-24, which asserted only
# that a change was "visible when editor2 refreshes". That is a weaker claim
# than the app actually makes: StepsController broadcasts step rows to the
# `workflow_<id>` stream, and the builder subscribes with turbo_stream_from, so
# the second editor is supposed to see changes *without* reloading. These tests
# assert the live behaviour, so if the broadcast is ever dropped the coverage
# fails instead of passing on a refresh that hides the regression.
class BuilderCollaborationTest < ApplicationSystemTestCase
  setup do
    @editor_one = create_editor
    @editor_two = create_editor

    # Editors may edit each other's Global workflows, which is the real
    # collaboration path — not an admin override.
    @created_global = Group.global.none?
    @workflow = file_in_global(Workflow.create!(
                                 title: "Shared Builder Workflow", user: @editor_one, status: "draft"
                               ))
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "All done", position: 0, resolution_type: "success"
    )
    @workflow.update!(start_step: @resolve)
  end

  # System tests commit, so a Global group this test made would outlive it.
  teardown do
    next unless @created_global

    GroupWorkflow.where(group: Group.global).delete_all
    Group.global.delete_all
  end

  test "a step renamed by one editor updates live for the other" do
    sign_in_as @editor_one
    visit_builder

    using_session(:editor_two) do
      sign_in_as @editor_two
      visit_builder
      assert_text "All done"
    end

    # Editor one renames the step through the panel, exactly as a user would.
    find("[data-step-uuid='#{@resolve.uuid}']").click
    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "All done", wait: 5
      fill_in "step[title]", with: "Renamed by editor one"
    end
    assert_eventually(timeout: 10) { @resolve.reload.title == "Renamed by editor one" }

    using_session(:editor_two) do
      # No visit, no reload — the broadcast has to carry it.
      assert_text "Renamed by editor one", wait: 10
      assert_no_text "All done"
    end
  end

  test "a step deleted by one editor disappears live for the other" do
    doomed = Steps::Question.create!(
      workflow: @workflow, title: "Doomed step", position: 1,
      question: "Doomed step", answer_type: "yes_no"
    )

    sign_in_as @editor_one
    visit_builder

    using_session(:editor_two) do
      sign_in_as @editor_two
      visit_builder
      assert_selector step_row_selector(doomed.uuid), wait: 5
    end

    row = find(step_row_selector(doomed.uuid))
    row.hover
    accept_confirm { row.find("button[title='Remove step']").click }
    assert_no_selector step_row_selector(doomed.uuid), wait: 5

    using_session(:editor_two) do
      assert_no_selector step_row_selector(doomed.uuid), wait: 10
    end
  end

  # Steps::TransitionsController re-streamed the Connections section to the
  # ACTING editor only, so the other editor's open panel kept a stale doors list
  # and target-picker candidates until it saved or was reopened. The step list
  # broadcast never covered it: that replaces rows, not the open panel.
  test "a connection made by one editor updates the other's open panel" do
    question = question_with_a_door

    sign_in_as @editor_one
    visit_builder
    open_step(question)
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes/ }

    using_session(:editor_two) { wire_yes_to_all_done(question) }

    # No visit, no reload, no save of our own - the broadcast has to carry it.
    within("turbo-frame#builder-panel") do
      assert_selector ".step-doors__row", text: /Yes.*All done/m, wait: 10
    end
  end

  # ...unless this editor is mid-edit in the connections editor itself, where
  # replacing the section would throw away a row they typed and never saved.
  # That is the failure the rendered/minted split exists to prevent, pointed the
  # other way.
  test "a refresh is declined while this editor has an unsaved connection row" do
    question = question_with_a_door

    sign_in_as @editor_one
    visit_builder
    open_step(question)

    # "Other connections" is a collapsed disclosure; the editor is inside it.
    within "turbo-frame#builder-panel" do
      find("summary", text: /Other connections/i).click
      click_on "Add Connection"
    end
    assert_selector "turbo-frame#builder-panel .transition-item", wait: 5

    using_session(:editor_two) { wire_yes_to_all_done(question) }

    within "turbo-frame#builder-panel" do
      assert_selector ".transition-item", wait: 5
      assert_text(/changed elsewhere/i, wait: 10)
    end
  end

  private

  def question_with_a_door
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?",
                                       question: "Light green?", position: 1,
                                       answer_type: "yes_no", variable_name: "light")
    @workflow.update!(start_step: question)
    question
  end

  # Editor two wires the Yes door to the Resolve, through the real dialog, so
  # Steps::TransitionsController actually runs and actually broadcasts.
  def wire_yes_to_all_done(question)
    sign_in_as @editor_two
    visit_builder
    open_step(question)
    within "turbo-frame#builder-panel" do
      find(".step-doors__row", text: "Yes").click_on "Use existing…"
    end
    assert_selector "dialog[open]", wait: 5
    within "dialog[open]" do
      fill_in "Find a step", with: "done"
      click_on "All done"
    end
    assert_eventually(timeout: 10) { question.transitions.reload.any? }
  end

  # Scoped to the row's own class: the warning icon also carries
  # data-step-uuid, so a bare attribute selector matches twice for any step
  # showing an issue.
  def step_row_selector(uuid)
    "#{STEP_ROW}[data-step-uuid='#{uuid}']"
  end

  def create_editor
    User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  def visit_builder
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end
end
