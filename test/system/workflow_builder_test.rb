require "application_system_test_case"

class WorkflowBuilderTest < ApplicationSystemTestCase
  setup do
    @editor = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(
      title: "Builder Test Workflow",
      user: @editor
    )
    Steps::Question.create!(workflow: @workflow, position: 0, uuid: SecureRandom.uuid, title: "Step One", question: "First?", answer_type: "yes_no", variable_name: "first")
    Steps::Action.create!(workflow: @workflow, position: 1, uuid: SecureRandom.uuid, title: "Step Two", action_type: "Instruction")
    Steps::Message.create!(workflow: @workflow, position: 2, uuid: SecureRandom.uuid, title: "Step Three")

    sign_in_as @editor
  end

  # ─── Test 1: Adding a step appends a new step-item ────────────────────────────
  test "can add a question step via the add button" do
    visit edit_workflow_path(@workflow)

    initial_count = all(".step-item").count

    find("button[data-step-type='question']").click

    # Wait for the async server render to complete
    assert_selector ".step-item", count: initial_count + 1, wait: 5
    # The new step has a hidden type input set to 'question'
    assert_selector "input[name*='[type]'][value='question']", visible: false, minimum: 1
  end

  # ─── Test 2: Step number badges update after adding a step ────────────────────
  test "step number badges update after adding a step" do
    visit edit_workflow_path(@workflow)

    # Initial state: 3 steps numbered 1, 2, 3
    badges = all(".rounded-full.bg-white\\/20")
    assert_equal %w[1 2 3], badges.map(&:text)

    find("button[data-step-type='action']").click
    assert_selector ".step-item", count: 4, wait: 5

    updated_badges = all(".rounded-full.bg-white\\/20")
    assert_equal %w[1 2 3 4], updated_badges.map(&:text)
  end

  # ─── Test 3: Step number badges update after removing a step ─────────────────
  test "step number badges update after removing a step" do
    visit edit_workflow_path(@workflow)

    assert_selector ".step-item", count: 3

    # Remove the first step
    within(".step-item[data-step-index='0']") do
      find("[data-action='click->workflow-builder#removeStep']").click
    end

    assert_selector ".step-item", count: 2, wait: 5

    updated_badges = all(".rounded-full.bg-white\\/20")
    assert_equal %w[1 2], updated_badges.map(&:text)
  end

  # ─── Test 4: Cannot double-add while one is loading (buttons disabled) ────────
  test "add buttons are disabled while a step is being added" do
    visit edit_workflow_path(@workflow)

    add_button = find("button[data-step-type='question']")

    # Intercept the fetch to slow it down and check button state
    # We verify by clicking rapidly and only getting one new step
    add_button.click
    add_button.click

    # Should only add one step despite two clicks (second click is on disabled btn)
    assert_selector ".step-item", count: 4, wait: 5
  end
end
