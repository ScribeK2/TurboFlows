require "test_helper"

# Validity and readiness are two different questions, and conflating them is what
# let a first-time editor publish a two-step workflow the product called perfect.
#
#   validity  — can this run? (graph: reachable, terminates in a Resolve)
#   readiness — is this ready for an agent? (do the steps actually SAY anything)
#
# A published workflow reported 0 errors and 0 warnings while shipping an empty
# Message body, empty Action instructions, and an Escalate with no destination —
# verified live in the Player, where the agent got a grey box labelled "Message".
#
# Readiness never blocks a publish (grill Q11): a hard block gets worked around by
# typing a space. It warns, and publishing asks for an explicit acknowledgement.
class WorkflowReadinessTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "readiness@example.com", password: "password123456", role: "editor")
    @workflow = Workflow.create!(title: "Readiness", user: @user)
    # `Group.global` is a SCOPE, so pushing it into the collection concats a
    # relation — and with no groups fixture that relation is empty, so this
    # assigned no audience at all and every check here ran against a workflow
    # carrying :no_audience. It passed only because a stale Global row was
    # sitting in the local test database; a reload surfaced it. The helper is
    # what creates Global in a test (see GlobalGroupHelper).
    file_in_global(@workflow)
  end

  test "a fully written workflow is ready" do
    build_linear_workflow
    assert_empty readiness_codes, "a complete workflow should report no readiness issues"
  end

  test "a message with no body is reported" do
    build_linear_workflow
    @message.content = ""
    @message.save!

    assert_includes readiness_codes, :message_body_required
  end

  test "an action with no instructions is reported" do
    build_linear_workflow
    @action.instructions = ""
    @action.save!

    assert_includes readiness_codes, :action_instructions_required
  end

  test "an escalate with no destination is reported" do
    build_linear_workflow
    @escalate.update!(target_type: nil, target_value: nil)

    assert_includes readiness_codes, :escalate_target_required
  end

  test "an escalate with a type but no name is still reported" do
    build_linear_workflow
    @escalate.update!(target_type: "team", target_value: "")

    assert_includes readiness_codes, :escalate_target_required
  end

  test "a question with no answer type is reported" do
    build_linear_workflow
    @question.update!(answer_type: nil)

    assert_includes readiness_codes, :answer_type_required
  end

  # Both label and value blank: the fallback in Steps::Question has nothing to
  # work from, so the option can never match a transition.
  test "an option with neither label nor value is reported" do
    build_linear_workflow
    @question.update!(options: [{ "label" => "", "value" => "" }])

    assert_includes readiness_codes, :option_value_missing
  end

  test "a step still carrying its generated placeholder title is reported" do
    build_linear_workflow
    @message.update!(title: "Untitled Message")

    assert_includes readiness_codes, :placeholder_title
  end

  # The trapdoor, closed. HealthFixesController#add_resolve_after conjures a
  # Resolve titled "Resolve" with no description when the workflow has none, so
  # one Fix click used to take a lone Question to a clean bill of health.
  test "no sequence of Fix clicks can reach a clean report" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Which error?", position: 1,
      question: "Ask them.", answer_type: "yes_no",
      options: [{ "label" => "Yes", "value" => "yes" }]
    )
    @workflow.update!(start_step: question)
    resolve = Steps::Resolve.create!(workflow: @workflow, title: "Resolve", position: 2, resolution_type: "success")
    Transition.create!(step: question, target_step: resolve, position: 0)

    result = WorkflowHealthCheck.call(@workflow.reload)

    assert_equal 0, result.summary[:errors], "the graph itself is valid"
    assert_not_empty result.readiness_issues,
                     "a Fix-created Resolve keeps its placeholder title and empty body, so it is not ready"
    assert_includes readiness_codes, :placeholder_title
  end

  test "readiness issues never block a publish" do
    build_linear_workflow
    @message.content = ""
    @message.save!

    result = WorkflowHealthCheck.call(@workflow.reload)
    assert_empty result.publish_blockers, "readiness warns; it does not refuse"
  end

  test "every readiness code is classified and none blocks publish" do
    overlap = WorkflowHealthCheck::READINESS_CODES & WorkflowHealthCheck::PUBLISH_BLOCKING_CODES
    assert_empty overlap, "readiness must never gate a publish: #{overlap.inspect}"

    unclassified = WorkflowHealthCheck::READINESS_CODES - WorkflowHealthCheck::NON_BLOCKING_CODES
    assert_empty unclassified,
                 "every readiness code must also appear in NON_BLOCKING_CODES: #{unclassified.inspect}"
  end

  private

  def readiness_codes
    WorkflowHealthCheck.call(@workflow.reload).readiness_issues.pluck(:code)
  end

  def build_linear_workflow
    @question = Steps::Question.create!(
      workflow: @workflow, title: "Which sign-in error?", position: 1,
      question: "Read the exact message.", answer_type: "multiple_choice",
      options: [{ "label" => "Locked", "value" => "locked" }]
    )
    @message = Steps::Message.create!(workflow: @workflow, title: "Talk them through it", position: 2)
    @message.content = "<p>Walk the customer through the reset.</p>"
    @message.save!
    @action = Steps::Action.create!(workflow: @workflow, title: "Unlock the account", position: 3)
    @action.instructions = "<p>Open the admin tool and unlock.</p>"
    @action.save!
    @escalate = Steps::Escalate.create!(
      workflow: @workflow, title: "Send to Tier 2", position: 4,
      target_type: "team", target_value: "Tier 2", priority: "medium"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "Customer is signed in", position: 5, resolution_type: "success"
    )
    @resolve.description = "<p>Confirm they are in before ending the call.</p>"
    @resolve.save!

    @workflow.update!(start_step: @question)
    Transition.create!(step: @question, target_step: @message, position: 0)
    Transition.create!(step: @message, target_step: @action, position: 0)
    Transition.create!(step: @action, target_step: @escalate, position: 0)
    Transition.create!(step: @escalate, target_step: @resolve, position: 0)
    @workflow.reload
  end
end
