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
    # An audience, so "clean" means the graph; the audience warning has its own tests below.
    file_in_global(@workflow)
  end

  # A choiceless select is not only a broken dropdown at run time. An export
  # carries schema_version, so it re-imports down the strict path where
  # StrictImportValidator refuses it — and nothing could write select_options
  # before 2026-09-04, so every select authored until then is in this state.
  # The health panel is where an operator finds which workflows to fix.
  test "a select field with no choices is flagged on its step" do
    form = Steps::Form.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0, title: "Collect",
      options: [{ "name" => "method", "label" => "How paid", "field_type" => "select" }]
    )
    resolve = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: form, target_step: resolve, position: 0)
    @workflow.update!(start_step: form)

    issues = WorkflowHealthCheck.new(@workflow.reload).call.issues[form.uuid]
    choiceless = issues.find { |i| i[:code] == :select_options_required }

    assert choiceless, "expected a select_options_required warning, got #{issues.inspect}"
    assert_equal :warning, choiceless[:severity]
    assert_match(/How paid/, choiceless[:message], "name the field so it can be found")
  end

  test "a select field whose choices are not label/value pairs is flagged too" do
    form = Steps::Form.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0, title: "Collect",
      options: [{ "name" => "method", "label" => "How paid", "field_type" => "select",
                  "select_options" => %w[IVR Link] }]
    )
    resolve = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: form, target_step: resolve, position: 0)
    @workflow.update!(start_step: form)

    issues = WorkflowHealthCheck.new(@workflow.reload).call.issues[form.uuid]

    assert(issues.any? { |i| i[:code] == :select_options_required },
           "a string array renders blank options, same as none at all")
  end

  test "a select field with real choices is not flagged" do
    form = Steps::Form.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0, title: "Collect",
      options: [{ "name" => "method", "label" => "How paid", "field_type" => "select",
                  "select_options" => [{ "label" => "IVR", "value" => "ivr" }] }]
    )
    resolve = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: form, target_step: resolve, position: 0)
    @workflow.update!(start_step: form)

    issues = WorkflowHealthCheck.new(@workflow.reload).call.issues[form.uuid]

    assert_not(issues.any? { |i| i[:code] == :select_options_required })
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

  test "step with no outgoing connections gets an error" do
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
    # An error, not a warning: publish refuses a terminal that is not a Resolve,
    # and this issue now stands in for that finding.
    assert(step_issues.any? { |i| i[:severity] == :error })
  end

  test "dead-end step offers a fix that works whether or not a resolve exists" do
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
    # Was connect_next. This issue now also stands in for terminal-not-Resolve,
    # so its Fix has to work when there is no next step to connect to —
    # connect_next answers that case with "No next step to connect to", while
    # add_resolve_after reuses an existing Resolve or creates one.
    assert_equal "add_resolve_after", dead_end_issue[:fix_type]
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
    # The wording moved: a step with no outgoing transitions now reports that
    # single fact rather than also restating it as "terminal step is not a
    # Resolve step" and "has no path to a Resolve step". The contract this test
    # exists for — the terminal step carries an error with a working Fix — is
    # unchanged, so it is asserted on the fix rather than on the old sentence.
    resolve_issue = action_issues.find { |i| i[:fix_type] == "add_resolve_after" }
    assert resolve_issue, "Expected a fixable terminal error on the action step"
    assert_equal :error, resolve_issue[:severity]
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

  # This check looked at step.title, and its test blanked the title, so a new
  # Question (always titled "Untitled Question", never given text) was never
  # flagged. Blank question text doesn't break a run: the runner shows the title.
  test "a question with no question text is flagged" do
    q = connected_step(Steps::Question, title: "Ask", question: nil, answer_type: "text")

    codes = WorkflowHealthCheck.call(@workflow.reload).issues[q.uuid].pluck(:code)

    assert_includes codes, :question_text_required
    assert_not_includes codes, :title_required
  end

  # Both fields are required by the import schema, so the warning has to say
  # what the author loses besides the run: the export comes back refused.
  test "the empty-field warnings say the export is refused" do
    q = connected_step(Steps::Question, title: "", question: nil, answer_type: "text")

    messages = WorkflowHealthCheck.call(@workflow.reload).issues[q.uuid]
                                  .select { %i[title_required question_text_required].include?(it[:code]) }
                                  .pluck(:message)

    assert_equal 2, messages.size
    messages.each { assert_includes it, "export is refused" }
  end

  test "a step with no title is flagged, whatever its type" do
    action = connected_step(Steps::Action, title: "", action_type: "Instruction")

    codes = WorkflowHealthCheck.call(@workflow.reload).issues[action.uuid].pluck(:code)

    assert_includes codes, :title_required
  end

  test "a titled question with text has neither warning" do
    q = connected_step(Steps::Question, title: "Ask", question: "What happened?", answer_type: "text")

    codes = WorkflowHealthCheck.call(@workflow.reload).issues[q.uuid].pluck(:code)

    assert_empty codes & %i[title_required question_text_required]
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

  # -- Slice 3b: one answer to "can this publish?" -----------------------------

  # WorkflowPublisher blocks on `GraphValidator#valid?`, which is simply
  # "@findings.any?" — the validator has no severity concept, so every finding it
  # produces stops a publish. The health check nonetheless singled out
  # :unreachable_step and called it a warning, so the builder showed a clear
  # Publish button and "Passing: every step can reach a Resolve step", and then
  # publish refused with "Step 'X' is not reachable from the start node".
  test "an unreachable step is an error, because publish refuses on it" do
    user = User.create!(email: "sev-#{SecureRandom.hex(4)}@example.com",
                        password: "password123!", password_confirmation: "password123!", role: "editor")
    workflow = Workflow.create!(title: "Severity Flow", user: user, status: "draft")
    q = Steps::Question.create!(workflow: workflow, position: 0, title: "Ask",
                                question: "What?", answer_type: "text")
    resolve = Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done",
                                     resolution_type: "success")
    orphan = Steps::Resolve.create!(workflow: workflow, position: 2, title: "Stranded",
                                    resolution_type: "success")
    Transition.create!(step: q, target_step: resolve, position: 0)
    workflow.update!(start_step: q)

    result = WorkflowHealthCheck.call(workflow)
    severities = result.issues[orphan.uuid].to_a.pluck(:severity)

    assert_includes severities, :error,
                    "publish refuses on an unreachable step, so the panel must call it an error"

    # And the two really do agree now.
    publish = WorkflowPublisher.publish(workflow, user)

    assert_not publish.success?, "precondition: publish refuses this workflow"
    assert_operator result.summary[:errors], :>, 0,
                    "the health panel must not report a publishable workflow when publish refuses"
  end

  test "reports an inescapable handoff mesh as a warning" do
    wf_a = Workflow.create!(title: "Health A", user: @user)
    wf_b = Workflow.create!(title: "Health B", user: @user)
    Steps::SubFlow.create!(workflow: wf_a, position: 0, title: "Hand to B",
                           sub_flow_workflow_id: wf_b.id, sub_flow_returns: false)
    Steps::SubFlow.create!(workflow: wf_b, position: 0, title: "Hand to A",
                           sub_flow_workflow_id: wf_a.id, sub_flow_returns: false)
    result = WorkflowHealthCheck.new(wf_a.reload).call
    issue = result.issues.values.flatten.find { |i| i[:code] == :no_resolve_across_workflows }
    assert issue, "expected a :no_resolve_across_workflows issue"
    assert_equal :warning, issue[:severity]
  end

  # The structural guard. Not a list of codes to keep in sync — the point is that
  # classify_graph_finding has no per-code severity decision left to drift.
  test "no graph finding is ever classified as a warning" do
    source = Rails.root.join("app/services/workflow_health_check.rb").read
    body = source[/def classify_graph_finding.*?\n  end\n/m]

    assert body, "classify_graph_finding not found"
    assert_no_match(/:warning/, body, <<~MESSAGE)
      classify_graph_finding names :warning.

      Every GraphValidator finding blocks a publish (WorkflowPublisher calls
      valid?, which is "@findings.any?"), so anything softer than :error means
      the builder is telling people a workflow is publishable when it is not.
      Severity belongs to the publisher's behaviour, not to a per-code opinion.
    MESSAGE
  end

  test "a workflow in no group warns first, on the workflow, that nobody can see it" do
    nobody = Workflow.create!(title: "Nobody Chosen", user: @user, status: "draft")

    issues = WorkflowHealthCheck.call(nobody).issues

    assert_equal "workflow", issues.keys.first
    audience = issues["workflow"].find { it[:code] == :no_audience }
    assert_equal :warning, audience[:severity]
  end

  test "a workflow with an audience has no audience warning" do
    codes = WorkflowHealthCheck.call(@workflow).issues.values.flatten.pluck(:code)

    assert_not_includes codes, :no_audience
  end

  # The runner records a field's answer as answer[<name>], so a field with no
  # name has nothing to record it under. (Strict import doesn't check this yet,
  # though the published schema requires both: see TODOS.)
  test "a form field missing its name or label is flagged" do
    form = connected_step(Steps::Form, title: "Collect",
                                       options: [{ "name" => "", "label" => "Callback number", "field_type" => "text" }])

    issue = WorkflowHealthCheck.call(@workflow.reload).issues[form.uuid].find { it[:code] == :form_field_incomplete }

    assert issue, "expected a form_field_incomplete warning"
    assert_equal :warning, issue[:severity]
    assert_includes issue[:message], "Callback number"
  end

  test "a Yes/No Question with one answer wired warns about the other" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC doors", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Light green?", question: "Light green?", position: 0,
                                answer_type: "yes_no", variable_name: "light")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    wf.update!(start_step: q)
    Transition.create!(step: q, target_step: done, condition: "light == 'yes'")

    issue = WorkflowHealthCheck.call(wf).issues[q.uuid].find { |i| i[:code] == :missing_expected_door }

    assert_equal :warning, issue[:severity]
    assert_equal "“No” has no step yet", issue[:message]
    assert_not issue[:fixable]
  end

  test "an Anything else connection silences the missing-door warning" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC default", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Q", question: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    other = Steps::Resolve.create!(workflow: wf, title: "Other", position: 2, resolution_type: "success")
    wf.update!(start_step: q)
    Transition.create!(step: q, target_step: done, condition: "q == 'yes'", position: 0)
    Transition.create!(step: q, target_step: other, position: 1)

    codes = WorkflowHealthCheck.call(wf).issues.fetch(q.uuid, []).pluck(:code)
    assert_not_includes codes, :missing_expected_door
  end

  test "a multi-door step with nothing wired says so once, with no one-click fix" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC none", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Q", question: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    wf.update!(start_step: q)

    issues = WorkflowHealthCheck.call(wf).issues[q.uuid]
    none = issues.find { |i| i[:code] == :no_outgoing_transitions }

    assert_equal "No answers lead anywhere yet", none[:message]
    assert_not none[:fixable]
    assert_nil none[:fix_type]
    assert_not_includes issues.pluck(:code), :missing_expected_door
  end

  test "a single-door step keeps its one-click fix" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC single", user: user)
    a = Steps::Action.create!(workflow: wf, title: "Do it", position: 0)
    wf.update!(start_step: a)

    none = WorkflowHealthCheck.call(wf).issues[a.uuid].find { |i| i[:code] == :no_outgoing_transitions }
    assert none[:fixable]
    assert_equal "add_resolve_after", none[:fix_type]
  end

  test "a connection checking for a value the step no longer offers is reported" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC stale", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Device?", question: "Device?", position: 0, variable_name: "device",
                                answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    wf.update!(start_step: q)
    Transition.create!(step: q, target_step: done, condition: "device == 'router'", position: 0)
    Transition.create!(step: q, target_step: done, condition: "device == 'modem'", position: 1)

    issue = WorkflowHealthCheck.call(wf).issues[q.uuid].find { |i| i[:code] == :unmatched_option_value }
    assert_equal :warning, issue[:severity]
    assert_equal "This connection checks for “modem”, which is no longer an option", issue[:message]
  end

  # A hand-made duplicate of a wired door's own condition is an "extra" (only
  # the first transition claims the door), but its value is still a real
  # answer - it must not be reported as though the step stopped offering it.
  test "a duplicate connection sharing a wired door's condition is not reported as unmatched" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC duplicate", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Q", question: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    also = Steps::Resolve.create!(workflow: wf, title: "Also", position: 2, resolution_type: "success")
    wf.update!(start_step: q)
    Transition.create!(step: q, target_step: done, condition: "q == 'yes'", position: 0)
    Transition.create!(step: q, target_step: also, condition: "q == 'yes'", position: 1)

    codes = WorkflowHealthCheck.call(wf).issues.fetch(q.uuid, []).pluck(:code)
    assert_not_includes codes, :unmatched_option_value
  end

  # Same as above, but the stale connection is a bare value with no operator -
  # the shape #Step::Doors#unmatched_extras learned to catch alongside the
  # operator form (see test/models/step_doors_test.rb).
  test "a bare stale connection value is reported too" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC bare stale", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Device?", question: "Device?", position: 0, variable_name: "device",
                                answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    wf.update!(start_step: q)
    Transition.create!(step: q, target_step: done, condition: "router", position: 0)
    Transition.create!(step: q, target_step: done, condition: "modem", position: 1)

    issue = WorkflowHealthCheck.call(wf).issues[q.uuid].find { |i| i[:code] == :unmatched_option_value }
    assert_equal :warning, issue[:severity]
    assert_equal "This connection checks for “modem”, which is no longer an option", issue[:message]
  end

  # A stale value containing a backslash is reported as it was WRITTEN
  # (Step::Doors#unmatched_extras now reports parsed[:literal_value]), not the
  # unescaped reading, which would silently drop the backslash.
  test "a stale connection value containing a backslash reports the value as written" do
    user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    wf = Workflow.create!(title: "HC backslash stale", user: user)
    q = Steps::Question.create!(workflow: wf, title: "Drive?", question: "Drive?", position: 0, variable_name: "path",
                                answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    wf.update!(start_step: q)
    Transition.create!(step: q, target_step: done, condition: "path == 'router'", position: 0)
    Transition.create!(step: q, target_step: done, condition: "path == 'D:\\gone'", position: 1)

    issue = WorkflowHealthCheck.call(wf).issues[q.uuid].find { |i| i[:code] == :unmatched_option_value }
    assert_equal :warning, issue[:severity]
    assert_equal "This connection checks for “D:\\gone”, which is no longer an option", issue[:message]
  end

  private

  # One step wired to a Resolve and set as the start, so the only findings on
  # it are about its own fields.
  def connected_step(klass, **attrs)
    step = klass.create!(workflow: @workflow, uuid: SecureRandom.uuid, position: 0, **attrs)
    resolve = Steps::Resolve.create!(workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
                                     title: "Done", resolution_type: "success")
    Transition.create!(step:, target_step: resolve, position: 0)
    @workflow.update!(start_step: step)
    step
  end
end
