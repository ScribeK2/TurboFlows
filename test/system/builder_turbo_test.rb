require "application_system_test_case"
require_relative "../support/multi_session_helper"

class BuilderTurboTest < ApplicationSystemTestCase
  include MultiSessionHelper

  setup do
    @editor = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Turbo Builder Test", user: @editor)
    Steps::Question.create!(
      workflow: @workflow, position: 0, uuid: SecureRandom.uuid,
      title: "First Question", question: "Q1?", answer_type: "yes_no", variable_name: "q1"
    )
    Steps::Resolve.create!(
      workflow: @workflow, position: 1, uuid: SecureRandom.uuid,
      title: "Done", resolution_type: "success"
    )

    sign_in_as @editor
  end

  test "step creation appends without full page reload" do
    visit edit_workflow_path(@workflow)
    assert_selector ".step-item", count: 2, wait: 5

    assert_no_full_reload do
      find("button[data-step-type='action']").click
      assert_selector ".step-item", count: 3, wait: 5
    end
  end

  test "clicking step row opens panel edit via Turbo Frame" do
    visit edit_workflow_path(@workflow)
    assert_selector ".step-item", count: 2, wait: 5

    assert_no_full_reload do
      first(".step-item").click
      assert_selector "[data-builder-target='panel']", wait: 5
    end
  end

  test "editing step title triggers autosave and persists" do
    visit edit_workflow_path(@workflow)
    assert_selector ".step-item", count: 2, wait: 5

    # Open the first step panel
    first(".step-item").click
    assert_selector "[data-builder-target='panel']", wait: 5

    # Find and update the title field in the panel
    within("[data-builder-target='panel']") do
      title_field = find("input[name*='[title]']", match: :first)
      title_field.fill_in with: "Updated Title"
    end

    # Wait for autosave debounce (2s) + network
    sleep 3

    # Reload page and verify title persisted
    visit edit_workflow_path(@workflow)
    assert_selector ".step-item", text: "Updated Title", wait: 5
  end

  test "large workflow with 50 steps renders within 5 seconds" do
    # Create 48 additional steps (already have 2)
    48.times do |i|
      Steps::Action.create!(
        workflow: @workflow, position: i + 2, uuid: SecureRandom.uuid,
        title: "Step #{i + 3}", action_type: "Instruction"
      )
    end

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    visit workflow_path(@workflow)
    assert_selector ".step-item", minimum: 50, wait: 10
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

    assert_operator elapsed, :<, 5.0, "50-step workflow took #{elapsed.round(2)}s to render (expected < 5s)"
  end
end
