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

    # Editors may edit each other's public workflows, which is the real
    # collaboration path — not an admin override.
    @workflow = Workflow.create!(
      title: "Shared Builder Workflow", user: @editor_one,
      status: "draft", is_public: true
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "All done", position: 0, resolution_type: "success"
    )
    @workflow.update!(start_step: @resolve)
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

  private

  # Scoped to the row's list semantics: the warning icon also carries
  # data-step-uuid, so a bare attribute selector matches twice for any step
  # showing an issue.
  def step_row_selector(uuid)
    "[role='listitem'][data-step-uuid='#{uuid}']"
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
