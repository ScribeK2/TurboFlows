# frozen_string_literal: true

require "test_helper"

class WorkflowHealthCheckTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "health-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    # Draft status avoids graph validation on save, letting us create intentionally broken workflows
    @workflow = Workflow.create!(title: "Health Test", user: @user, status: "draft")
  end

  test "clean workflow returns no issues" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    r = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: q, target_step: r, position: 0)
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)

    assert_predicate result, :clean?
    assert_equal 0, result.summary[:total]
    assert_equal 0, result.summary[:errors]
    assert_equal 0, result.summary[:warnings]
  end

  test "step with no outgoing connections gets warning" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)

    assert_not result.clean?
    step_issues = result.issues[q.uuid]
    assert(step_issues.any? { |i| i[:message].include?("No outgoing connections") })
    assert(step_issues.any? { |i| i[:severity] == :warning })
  end

  test "dead-end step offers connect_next fix" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)
    dead_end_issue = result.issues[q.uuid].find { |i| i[:message].include?("No outgoing connections") }

    assert dead_end_issue[:fixable]
    assert_equal "connect_next", dead_end_issue[:fix_type]
  end

  test "terminal non-resolve step gets error with add_resolve_after fix" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    a = Steps::Action.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Do thing"
    )
    Transition.create!(step: q, target_step: a, position: 0)
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)
    action_issues = result.issues[a.uuid]

    assert_predicate action_issues, :present?
    resolve_issue = action_issues.find { |i| i[:message].include?("not a Resolve step") }
    assert resolve_issue, "Expected terminal-not-Resolve error on action step"
    assert resolve_issue[:fixable]
    assert_equal "add_resolve_after", resolve_issue[:fix_type]
  end

  # Regression: step titles are not unique, and the health check used to find a
  # step by matching the validator's English error message back to a title. Two
  # steps sharing a title meant the issue — and its Fix button — could attach to
  # the wrong one.
  test "duplicate step titles attach the terminal error to the correct step" do
    first = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Check account status", question: "What?", answer_type: "text"
    )
    second = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Check account status", question: "What?", answer_type: "text"
    )
    Transition.create!(step: first, target_step: second, position: 0)
    @workflow.update!(start_step: first)

    result = WorkflowHealthCheck.call(@workflow.reload)

    terminal_issue = lambda do |uuid|
      Array(result.issues[uuid]).find { |i| i[:fix_type] == "add_resolve_after" }
    end

    assert terminal_issue.call(second.uuid),
           "Expected the terminal-not-Resolve error on the dead-end step, got issues: #{result.issues.inspect}"
    assert_nil terminal_issue.call(first.uuid),
               "The first step has an outgoing transition and is not terminal — it must not carry the fix"
  end

  test "empty workflow returns clean result" do
    result = WorkflowHealthCheck.call(@workflow)

    assert_predicate result, :clean?
  end

  test "question without title gets warning" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "", question: "What?", answer_type: "text"
    )
    r = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: q, target_step: r, position: 0)
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)
    step_issues = result.issues[q.uuid]

    assert(step_issues.any? { |i| i[:message].include?("Question text is required") })
  end

  test "summary counts errors and warnings separately" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "", question: "What?", answer_type: "text"
    )
    a = Steps::Action.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Do thing"
    )
    Transition.create!(step: q, target_step: a, position: 0)
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)

    assert_operator result.summary[:total], :>, 0
    assert_equal result.summary[:errors] + result.summary[:warnings], result.summary[:total]
  end

  test "resolve step with no transitions does not get dead-end warning" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    r = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: q, target_step: r, position: 0)
    @workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(@workflow.reload)

    # Resolve steps are excluded from the dead-end check
    resolve_issues = result.issues[r.uuid]
    if resolve_issues
      assert_not(resolve_issues.any? { |i| i[:message].include?("No outgoing connections") })
    end
  end

  test "subflow step without target workflow gets warning" do
    # Create a valid graph first so the workflow can save
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    r = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: q, target_step: r, position: 0)
    @workflow.update!(start_step: q)

    # Now add a sub-flow step with no target, bypassing workflow validation
    sf = Steps::SubFlow.new(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 2,
      title: "Sub", sub_flow_workflow_id: nil
    )
    sf.save!(validate: false)

    result = WorkflowHealthCheck.call(@workflow.reload)
    step_issues = result.issues[sf.uuid]

    assert(step_issues.any? { |i| i[:message].include?("Sub-flow target is required") })
  end

  test "Result data object supports clean? method" do
    result = WorkflowHealthCheck::Result.new(
      issues: {},
      summary: { errors: 0, warnings: 0, total: 0 }
    )

    assert_predicate result, :clean?
  end

  test "Result data object clean? returns false when issues exist" do
    result = WorkflowHealthCheck::Result.new(
      issues: { "uuid-1" => [{ severity: :error, message: "test" }] },
      summary: { errors: 1, warnings: 0, total: 1 }
    )

    assert_not result.clean?
  end
end
