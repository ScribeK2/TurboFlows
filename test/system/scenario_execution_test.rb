require "application_system_test_case"

# Characterization test for the Scenario runner.
#
# Written deliberately against *semantics* — visible text, labels and the
# scenario-step behaviour hook — never against CSS classes or step numbering.
# The runner redesign deletes the stepper pills, the progress bar, the step
# number badges and the radio-card icon vocabulary; this test must survive all
# of that and still prove the runner routes, reverses and resolves correctly.
class ScenarioExecutionTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @workflow = Workflow.create!(title: "Scenario E2E Workflow", user: @user, status: "published")

    @question = Steps::Question.create!(
      workflow: @workflow, title: "Is the site down?", position: 0,
      question: "Is the site down?", answer_type: "yes_no"
    )
    @down_branch = Steps::Action.create!(
      workflow: @workflow, title: "Check hosting status", position: 1,
      action_type: "Instruction"
    )
    @up_branch = Steps::Message.create!(
      workflow: @workflow, title: "No outage detected", position: 2
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "Issue closed", position: 3,
      resolution_type: "success"
    )

    Transition.create!(step: @question, target_step: @down_branch, condition: "yes", position: 0)
    Transition.create!(step: @question, target_step: @up_branch, condition: "no", position: 1)
    Transition.create!(step: @down_branch, target_step: @resolve, position: 0)
    Transition.create!(step: @up_branch, target_step: @resolve, position: 0)

    @workflow.update!(start_step: @question)

    sign_in_as @user
  end

  test "a yes answer routes down the yes branch" do
    start_scenario

    assert_current_step "Is the site down?"
    choose_answer "Yes"

    assert_current_step "Check hosting status"
  end

  test "a no answer routes down the no branch" do
    start_scenario

    assert_current_step "Is the site down?"
    choose_answer "No"

    assert_current_step "No outage detected"
  end

  test "back returns to the previous step" do
    start_scenario

    assert_current_step "Is the site down?"
    choose_answer "Yes"
    assert_current_step "Check hosting status"

    click_on "Back"

    assert_current_step "Is the site down?"
  end

  test "completing a resolve step ends the run and shows results" do
    start_scenario

    choose_answer "Yes"
    assert_current_step "Check hosting status"
    click_on "Continue"

    assert_current_step "Issue closed"
    click_on "Complete Workflow"

    assert_text "Scenario Results", wait: 5
    assert_text "Is the site down?"
    assert_text "Check hosting status"
  end

  test "a sub-flow step hands off into the child workflow" do
    child = Workflow.create!(title: "Verification Sub-Flow", user: @user, status: "published")
    child_question = Steps::Question.create!(
      workflow: child, title: "Did the client verify?", position: 0,
      question: "Did the client verify?", answer_type: "yes_no"
    )
    child_resolve = Steps::Resolve.create!(
      workflow: child, title: "Verification complete", position: 1,
      resolution_type: "success"
    )
    Transition.create!(step: child_question, target_step: child_resolve, position: 0)
    child.update!(start_step: child_question)

    sub_flow = Steps::SubFlow.create!(
      workflow: @workflow, title: "Run verification", position: 4,
      sub_flow_workflow_id: child.id
    )
    Transition.where(step: @question, condition: "yes").destroy_all
    Transition.create!(step: @question, target_step: sub_flow, condition: "yes", position: 0)
    Transition.create!(step: sub_flow, target_step: @down_branch, position: 0)

    start_scenario

    assert_current_step "Is the site down?"
    choose_answer "Yes"

    # The sub-flow is auto-processed: the runner should land on the child
    # workflow's first step, not on the sub-flow step itself.
    assert_current_step "Did the client verify?"
  end

  test "an unanswered question does not advance" do
    start_scenario

    assert_current_step "Is the site down?"

    # Nothing selected: the runner must stay put rather than submitting a blank
    # answer and routing on the fallback transition.
    assert_no_text "Check hosting status"
    assert_no_text "No outage detected"
  end

  private

  def start_scenario
    visit new_workflow_execution_path(@workflow)
    click_on "Start Workflow"
  end
end
