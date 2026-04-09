require "application_system_test_case"

class ConcurrentEditingTest < ApplicationSystemTestCase
  setup do
    @editor1 = User.create!(
      email: "wf-system-test-editor1-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @editor2 = User.create!(
      email: "wf-system-test-editor2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Concurrent Edit Test", user: @editor1, is_public: true)
    Steps::Question.create!(
      workflow: @workflow, position: 0, uuid: SecureRandom.uuid,
      title: "Initial Question", question: "Q?", answer_type: "yes_no", variable_name: "q1"
    )
  end

  test "step added by editor1 is visible when editor2 refreshes" do
    # Editor 1 session: add a step
    using_session(:editor1) do
      sign_in_as @editor1
      visit edit_workflow_path(@workflow)
      assert_selector ".step-item", count: 1, wait: 5

      find("button[data-step-type='action']").click
      assert_selector ".step-item", count: 2, wait: 5
    end

    # Editor 2 session: verify the step is visible after page load
    using_session(:editor2) do
      sign_in_as @editor2
      visit edit_workflow_path(@workflow)
      assert_selector ".step-item", count: 2, wait: 5
    end
  end

  test "both editors can view the same workflow simultaneously" do
    using_session(:editor1) do
      sign_in_as @editor1
      visit workflow_path(@workflow)
      assert_selector "h1", text: "Concurrent Edit Test", wait: 5
    end

    using_session(:editor2) do
      sign_in_as @editor2
      visit workflow_path(@workflow)
      assert_selector "h1", text: "Concurrent Edit Test", wait: 5
    end
  end
end
