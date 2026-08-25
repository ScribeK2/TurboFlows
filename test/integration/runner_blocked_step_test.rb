require "test_helper"

# Escalate and Resolve refuse to advance when their required field is empty.
#
# A browser cannot reach these: both partials render `required` on the textarea
# and the scenario-step controller submits with requestSubmit(), which runs
# native constraint validation. They are a server-side backstop, so the only
# way to exercise them — and the only way to prove the backstop reports itself
# rather than failing silently — is to post directly.
#
# Both runners are covered because the whole point is that they agree.
class RunnerBlockedStepTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "blocked-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!",
                         role: "editor")
    @workflow = Workflow.create!(title: "Blocked Run", user: @user, status: "published")
    sign_in @user
  end

  test "scenario runner reports a missing escalation reason instead of swallowing it" do
    scenario = scenario_at(escalate_step)

    post next_step_scenario_path(scenario), params: { escalation_reason: "" }

    assert_response :unprocessable_content
    assert_includes response.body, "Escalation reason is required"
    assert_unchanged scenario
  end

  test "scenario runner reports missing resolution notes instead of swallowing them" do
    scenario = scenario_at(resolve_step)

    post next_step_scenario_path(scenario), params: { resolution_notes: "" }

    assert_response :unprocessable_content
    assert_includes response.body, "Resolution notes are required"
    assert_unchanged scenario
  end

  test "player runner reports a missing escalation reason instead of swallowing it" do
    scenario = scenario_at(escalate_step, purpose: "live")

    post player_scenario_next_path(scenario), params: { escalation_reason: "" }

    assert_response :unprocessable_content
    assert_includes response.body, "Escalation reason is required"
    assert_unchanged scenario
  end

  test "player runner reports missing resolution notes instead of swallowing them" do
    scenario = scenario_at(resolve_step, purpose: "live")

    post player_scenario_next_path(scenario), params: { resolution_notes: "" }

    assert_response :unprocessable_content
    assert_includes response.body, "Resolution notes are required"
    assert_unchanged scenario
  end

  test "a supplied reason advances the run, so the backstop is not simply blocking everything" do
    scenario = scenario_at(escalate_step)

    post next_step_scenario_path(scenario), params: { escalation_reason: "Customer waiting 15 min" }

    assert_response :redirect
    assert_equal "Customer waiting 15 min", scenario.reload.results.dig("_escalation", "reason")
  end

  private

  # A refused step leaves the run exactly where it was, with nothing recorded.
  def assert_unchanged(scenario)
    scenario.reload
    assert_predicate scenario, :active?
    assert_empty scenario.execution_path
  end

  def escalate_step
    @escalate_step ||= begin
      step = Steps::Escalate.create!(workflow: @workflow, title: "Escalate", position: 0,
                                     reason_required: true, target_type: "supervisor")
      done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1,
                                    resolution_type: "success")
      Transition.create!(step: step, target_step: done, position: 0)
      step
    end
  end

  def resolve_step
    @resolve_step ||= Steps::Resolve.create!(workflow: @workflow, title: "Wrap up", position: 2,
                                             notes_required: true, resolution_type: "success")
  end

  def scenario_at(step, purpose: "simulation")
    Scenario.create!(workflow: @workflow, user: @user, purpose: purpose,
                     current_node_uuid: step.uuid, execution_path: [], results: {}, inputs: {})
  end
end
