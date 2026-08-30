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

  # A required checkbox now renders `required`, so this refusal is a backstop
  # too: it stays the server's answer for any client that skips the attribute.
  test "form step reports an unchecked required checkbox" do
    form = Steps::Form.create!(
      workflow: @workflow, title: "Verify", position: 3,
      options: [{ "name" => "identity_confirmed", "label" => "Confirmed identity",
                  "field_type" => "checkbox", "required" => true, "position" => 0 }]
    )
    scenario = scenario_at(form)

    post next_step_scenario_path(scenario)

    assert_response :unprocessable_content
    assert_includes response.body, "Confirmed identity is required"
    assert_unchanged scenario
  end

  # Where a form's messages land.
  #
  # Escalate and Resolve have exactly one field each, so a summary block sits
  # next to the thing it is about. A form does not: on a long one the agent had
  # to match each sentence back to an input by reading the label out of it.
  test "a form's message renders under the field that failed, not in a block above" do
    scenario = scenario_at(two_field_form)

    post next_step_scenario_path(scenario), params: { answer: { "account" => "AC-1" } }

    assert_response :unprocessable_content
    assert_select ".player-form-field" do |fields|
      failing = fields.find { |f| f.to_s.include?("answer[customer_name]") }
      assert failing, "precondition: the failing field is on the page"
      assert_includes failing.to_s, "Customer name is required",
                      "the message belongs under the input it is about"
    end
    assert_select "#runner-step-errors", 0,
                  "a message that found its field has no business in the summary block too"
  end

  test "the control that failed marks itself, and the one that passed does not" do
    scenario = scenario_at(two_field_form)

    post next_step_scenario_path(scenario), params: { answer: { "account" => "AC-1" } }

    assert_select "input[name='answer[customer_name]'].is-invalid", 1
    assert_select "input[name='answer[account]'].is-invalid", 0,
                  "marking a field the agent filled in correctly teaches them to ignore the marking"
  end

  # The backstop was not a backstop: it refused everything.
  #
  # params[:answer] arrives as ActionController::Parameters, which is not a Hash
  # — is_a?(Hash) is false for it since Rails 5 — and process_form_step guarded
  # on exactly that, so every response was discarded and every required field
  # reported missing however the form was filled in. A form step with any
  # required field could not be submitted at all. Nothing caught it because no
  # test had ever submitted a *complete* form.
  test "a completed form advances, so the backstop is not simply blocking everything" do
    scenario = scenario_at(two_field_form)

    post next_step_scenario_path(scenario),
         params: { answer: { "customer_name" => "Ada Lovelace", "account" => "AC-1" } }

    assert_response :success, "an accepted answer streams forward; only a refusal is a 422"
    assert_equal "Ada Lovelace", scenario.reload.results["customer_name"]
    assert_equal({ "customer_name" => "Ada Lovelace", "account" => "AC-1" },
                 StepResponse.find_by(scenario: scenario).responses,
                 "the answers have to reach the record, not just the results bag")
  end

  test "a supplied reason advances the run, so the backstop is not simply blocking everything" do
    scenario = scenario_at(escalate_step)

    post next_step_scenario_path(scenario), params: { escalation_reason: "Customer waiting 15 min" }

    assert_response :success, "an accepted answer streams forward; only a refusal is a 422"
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

  def two_field_form
    @two_field_form ||= begin
      step = Steps::Form.create!(
        workflow: @workflow, title: "Verify the caller", position: 4,
        options: [
          { "name" => "customer_name", "label" => "Customer name", "field_type" => "text",
            "required" => true, "position" => 0 },
          { "name" => "account", "label" => "Account", "field_type" => "text",
            "required" => true, "position" => 1 }
        ]
      )
      done = Steps::Resolve.create!(workflow: @workflow, title: "Form Done", position: 5,
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
