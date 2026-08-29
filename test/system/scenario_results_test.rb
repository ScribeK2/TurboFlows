require "application_system_test_case"

# Characterization test for the Scenario results page, which had no coverage.
#
# Written against semantics where it can be. The two exceptions are the
# assertions that a specific element is *gone* — there the class is the thing
# being deleted, so naming it is the precise way to pin the change rather than
# a coupling to styling.
class ScenarioResultsTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )

    @workflow = Workflow.create!(title: "Results E2E Workflow", user: @user, status: "published")
    @question = Steps::Question.create!(
      workflow: @workflow, title: "Is the site down?", position: 0,
      question: "Is the site down?", answer_type: "yes_no"
    )
    @action = Steps::Action.create!(
      workflow: @workflow, title: "Check hosting status", position: 1, action_type: "Instruction"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "Issue closed", position: 2, resolution_type: "success"
    )
    Transition.create!(step: @question, target_step: @action, position: 0)
    Transition.create!(step: @action, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)

    sign_in_as @user
    complete_a_run
  end

  test "the run is summarised in one sentence, not a row of pills" do
    assert_selector "h1", text: "Scenario Results"

    # scenario_summary_sentence has existed and been tested since before this
    # work; no view called it, while the header rendered the same facts as four
    # separate pills.
    assert_text(/Completed 3 steps in/)
    assert_text(/1 question answered/)
    assert_text(/resolved as Success/)

    assert_no_selector ".scenario-stats"
  end

  test "execution rows name each step once, with no constant checkmark" do
    assert_text "Is the site down?"
    assert_text "Check hosting status"
    assert_text "Issue closed"

    # Every row in an execution path is completed by definition, so a check on
    # each one carried no information.
    assert_no_selector ".scenario-result-badge"
  end

  test "expanding a row reveals what was answered" do
    assert_no_text "yes", wait: 1

    find("button", text: "Is the site down?").click

    assert_text "Answer", wait: 5
    assert_text "yes"
  end

  test "a stopped run still shows its exceptional-state pill" do
    scenario = Scenario.where(workflow: @workflow).order(:created_at).last
    scenario.update!(status: "stopped", stopped_at_step_index: 1)

    visit scenario_path(scenario)

    # Pills survive only where they mark something exceptional.
    assert_selector ".badge--alert", text: /Workflow Stopped/
  end

  private

  def complete_a_run
    visit new_workflow_execution_path(@workflow)
    click_on "Start Workflow"
    assert_selector RUNNER_STEP_CARD, wait: 5
    choose_answer "Yes"
    assert_current_step "Check hosting status"
    click_on "Continue"
    assert_current_step "Issue closed"
    click_on "Complete Workflow"
    view_results
    assert_selector "h1", text: "Scenario Results", wait: 5
  end
end
