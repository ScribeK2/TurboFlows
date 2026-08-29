require "application_system_test_case"

# The stacked runner in a real browser.
#
# The point of streaming is that answering a step does not reload the page, and
# that is exactly what a request test cannot see — it can confirm the response
# is a turbo-stream, but not that the browser applied it in place. These tests
# stamp a value on `window` and assert it survives the answer: a full navigation
# would wipe it.
class StackedRunnerSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-stacked-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    Rails.configuration.x.stacked_runner = true

    @workflow = Workflow.create!(title: "Stacked System WF", user: @user, status: "published")
    @q1 = Steps::Question.create!(
      workflow: @workflow, title: "Is the account verified", position: 0,
      variable_name: "verified", question: "Is the account verified?", answer_type: "yes_no"
    )
    @q2 = Steps::Question.create!(
      workflow: @workflow, title: "Did the email arrive", position: 1,
      variable_name: "emailed", question: "Did the email arrive?", answer_type: "yes_no"
    )
    Steps::Resolve.create!(workflow: @workflow, title: "Close the call", position: 2, resolution_type: "success")
    Transition.create!(step: @q1, target_step: @q2, position: 0)
    Transition.create!(step: @q2, target_step: @workflow.steps.find_by(title: "Close the call"), position: 0)
    @workflow.update!(start_step: @q1)
  end

  teardown do
    Rails.configuration.x.stacked_runner = false
  end

  def start_scenario(purpose: "simulation")
    Scenario.create!(
      workflow: @workflow, user: @user, purpose: purpose, started_at: Time.current,
      current_node_uuid: @q1.uuid, execution_path: [], results: {}, inputs: {}
    )
  end

  # Stamps an expando property on the first answered row's DOM node.
  #
  # Not a `window` flag: classic answers with a redirect, and Turbo Drive
  # handles a redirect as a visit that swaps the body while keeping the same JS
  # context — so `window` survives both paths and proves nothing. A node does
  # not: streaming leaves the rows above the tail untouched, while a Drive visit
  # rebuilds them, so identity of the node is the honest discriminator.
  def mark_first_row
    page.execute_script("document.querySelector('.runner-thread__row').dataset.marked = 'yes'; " \
                        "document.querySelector('.runner-thread__row').__survived = true")
  end

  def first_row_survived?
    page.evaluate_script("!!(document.querySelector('.runner-thread__row') || {}).__survived")
  end

  test "answering leaves the transcript above it untouched" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    mark_first_row

    choose_answer "Yes"
    assert_current_step "Close the call"

    assert_predicate self, :first_row_survived?,
                     "the rows above the answer were rebuilt — the page repainted instead of streaming"
    assert_selector ".runner-thread__row", count: 2
  end

  test "the answered step stays on screen as a row" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    choose_answer "Yes"
    assert_current_step "Did the email arrive"

    assert_selector ".runner-thread__row", text: "Is the account verified"
    assert_selector ".runner-thread__row .runner-thread__summary", text: "yes"
  end

  test "auto-advance submits once" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    choose_answer "Yes"
    assert_current_step "Did the email arrive"

    assert_selector ".runner-thread__row", count: 1,
                                           wait: 3
  end

  test "refreshing mid-run restores the same thread" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)
    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    rows_before = all(".runner-thread__row").size

    visit step_scenario_path(scenario)

    assert_current_step "Did the email arrive"
    assert_equal rows_before, all(".runner-thread__row").size,
                 "a streamed thread and a reloaded one must not disagree"
  end

  test "Enter submits when focus is in the card" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    # Keydown is scoped to the card now, so focus being inside it is what makes
    # the shortcut work at all.
    choose_answer "Yes"

    assert_current_step "Did the email arrive"
  end

  test "the Player streams too" do
    scenario = start_scenario(purpose: "live")
    sign_in_as(@user)
    visit player_scenario_step_path(scenario)
    assert_current_step "Is the account verified"

    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    mark_first_row

    choose_answer "Yes"
    assert_current_step "Close the call"

    assert_predicate self, :first_row_survived?, "the Player repainted — both shells must stream"
    assert_selector ".runner-thread__row", text: "Is the account verified"
  end
  test "an anonymous shared run streams like any other" do
    @workflow.update!(share_token: SecureRandom.hex(8))

    visit shared_player_path(@workflow.share_token)
    assert_current_step "Is the account verified"

    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    mark_first_row

    choose_answer "Yes"
    assert_current_step "Close the call"

    assert_predicate self, :first_row_survived?,
                     "share links are the surface least able to report what they saw — " \
                     "they must not silently fall back to reloading"
  end
end
