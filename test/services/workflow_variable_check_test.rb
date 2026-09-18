require "test_helper"

# Branches that can never fire, and step copy that shows an agent raw braces.
#
# The shape both come from is one move in the step panel: rename a Question's
# variable_name and every condition written against the old name keeps it.
# Nothing rewrites them and nothing refuses the save, so until this check ran
# the health panel reported zero errors on a workflow nobody could finish.
class WorkflowVariableCheckTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "varcheck-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!",
                         role: "editor")
    @workflow = Workflow.create!(title: "Variables", user: @user, status: "draft")
  end

  def check
    WorkflowVariableCheck.call(@workflow.reload, @workflow.steps.includes(transitions: :target_step).to_a)
  end

  # The same path the builder's Templates popover uses.
  def apply_template(key)
    template = WorkflowTemplate.find(key)
    controller = StepsController.new
    controller.instance_variable_set(:@workflow, @workflow)
    steps_data, first_uuid = controller.send(:build_steps_data_from_template, template)
    StepBuilder.call(@workflow, steps_data, start_node_uuid: first_uuid, replace: true)
  end

  def question(variable_name:, title: "Why are they calling?")
    Steps::Question.create!(workflow: @workflow, position: 0, title: title, question: title,
                            answer_type: "choice", variable_name: variable_name,
                            options: [{ "label" => "Billing", "value" => "billing" }])
  end

  def resolve(position: 1, title: "Done")
    Steps::Resolve.create!(workflow: @workflow, position: position, title: title, resolution_type: "success")
  end

  # --- the rename, end to end ------------------------------------------------

  test "a condition naming a variable nothing sets is reported on the source step" do
    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "call_reason == 'billing'", position: 0)

    findings = check

    assert_equal 1, findings.size
    assert_equal :undefined_variable, findings.first.code
    assert_equal q.uuid, findings.first.step_uuid, "the step whose branches will not fire"
    assert_equal ["call_reason"], findings.first.variables
  end

  test "a condition naming a variable a question does set is not reported" do
    q = question(variable_name: "call_reason")
    Transition.create!(step: q, target_step: resolve, condition: "call_reason == 'billing'", position: 0)

    assert_empty check
  end

  # --- everything that counts as "set" ---------------------------------------
  # Six writers, all in ScenarioStepProcessor. Missing any of them means warning
  # on a workflow that works, which is the one thing this must not do.

  test "a step title counts, because the runtime writes results[title]" do
    q = question(variable_name: "reason", title: "escalation_tier")
    Transition.create!(step: q, target_step: resolve, condition: "escalation_tier == 'two'", position: 0)

    assert_empty check, "StepResolver reads results[variable_name] || results[title]"
  end

  test "an Action output_field counts" do
    q = question(variable_name: "reason")
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Look it up",
                                   output_fields: [{ "name" => "ticket_id", "value" => "T-1" }])
    Transition.create!(step: q, target_step: action, position: 0)
    Transition.create!(step: action, target_step: resolve(position: 2), condition: "ticket_id == 'T-1'", position: 0)

    assert_empty check, "this is the false positive StrictImportValidator still has"
  end

  test "a Form field counts" do
    form = Steps::Form.create!(workflow: @workflow, position: 0, title: "Collect details",
                               options: [{ "name" => "account_number", "label" => "Account number",
                                           "field_type" => "text", "required" => true, "position" => 0 }])
    Transition.create!(step: form, target_step: resolve, condition: "account_number == '42'", position: 0)

    assert_empty check
  end

  # --- interpolation ---------------------------------------------------------

  test "an unknown variable in a question's text is reported" do
    q = question(variable_name: "reason", title: "Ask about {{account_tier}}")
    Transition.create!(step: q, target_step: resolve, position: 0)

    findings = check

    assert_equal [:undefined_interpolation], findings.map(&:code)
    assert_equal ["account_tier"], findings.first.variables
  end

  test "an unknown variable in a rich text body is reported" do
    q = question(variable_name: "reason")
    message = Steps::Message.create!(workflow: @workflow, position: 1, title: "Read this out")
    message.content = "<p>Tell them about {{their_plan}}.</p>"
    message.save!
    Transition.create!(step: q, target_step: message, position: 0)
    Transition.create!(step: message, target_step: resolve(position: 2), position: 0)

    findings = check.select { |f| f.code == :undefined_interpolation }

    assert_equal [message.uuid], findings.map(&:step_uuid),
                 "the prose an agent reads on a call is all ActionText"
    assert_equal ["their_plan"], findings.first.variables
  end

  # It was NOT reported until the runtime learned to interpolate it. This check
  # references VariableInterpolator::VARIABLE_PATTERN rather than copying it, so
  # when that pattern began allowing inner spaces this followed with no edit.
  test "a spaced interpolation is an interpolation, so an unknown one is reported" do
    q = question(variable_name: "reason", title: "Ask about {{ account_tier }}")
    Transition.create!(step: q, target_step: resolve, position: 0)

    assert_equal [["account_tier"]], check.map(&:variables)
  end

  test "one finding per step, naming every unknown variable on it" do
    q = question(variable_name: "reason", title: "Ask {{one}} and {{two}} and {{three}}")
    Transition.create!(step: q, target_step: resolve, position: 0)

    findings = check

    assert_equal 1, findings.size, "three unknowns on one step is one problem, not three"
    assert_equal %w[one two three], findings.first.variables
  end

  # --- found in review: three ways this warned on a branch that fires --------

  # condition_preset_controller.js#buildPresets writes `step.variable_name || "answer"`,
  # so a Question with no variable_name gets `answer == 'yes'` from the builder's
  # OWN preset picker, and ConditionEvaluator#lookup_value resolves "answer" as
  # the last value given. Warning on that is warning on the product's default output.
  test "the legacy name `answer` is never reported" do
    q = question(variable_name: nil)
    Transition.create!(step: q, target_step: resolve, condition: "answer == 'billing'", position: 0)

    assert_empty check
    assert ConditionEvaluator.evaluate("answer == 'billing'", { q.title => "billing" }),
           "and the runtime agrees it fires"
  end

  # lookup_value falls back to a case-insensitive key match.
  test "a condition matches its variable whatever the case" do
    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "Reason == 'billing'", position: 0)

    assert_empty check
    assert ConditionEvaluator.evaluate("Reason == 'billing'", { "reason" => "billing" })
  end

  # A caller's variable_mapping RENAMES on the way in: {"account_tier" => "tier"}
  # seeds the child with `tier`, which no step anywhere sets under that name.
  test "a name a caller's variable_mapping creates counts in the target" do
    parent = Workflow.create!(title: "Mapper", user: @user, status: "draft")
    Steps::Question.create!(workflow: parent, position: 0, title: "Tier?", question: "Tier?",
                            answer_type: "text", variable_name: "account_tier")
    Steps::SubFlow.create!(workflow: parent, position: 1, title: "Run the child",
                           sub_flow_workflow_id: @workflow.id, sub_flow_returns: true,
                           variable_mapping: { "account_tier" => "tier" })

    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "tier == 'gold'", position: 0)

    assert_empty check
  end

  # --- found in review: the message was wrong for half the operators ---------

  # Against a variable nothing sets, `!=` evaluates TRUE (nil means true) and
  # `<` / `<=` compare against 0 — so those branches ALWAYS fire, and one that
  # comes first shadows every branch after it. "They will not fire" described
  # the opposite of the worse failure.
  test "the message does not claim a branch will not fire when it always will" do
    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "gone != 'x'", position: 0)

    assert ConditionEvaluator.evaluate("gone != 'x'", {}), "precondition: this branch always fires"

    message = WorkflowHealthCheck.call(@workflow.reload).issues.values.flatten
                                 .find { |i| i[:code] == :undefined_variable }[:message]
    assert_no_match(/will not fire/, message)
  end

  # --- found in review: cost --------------------------------------------------

  # One shared sub-flow called by most workflows pulls nearly every workflow
  # into the closure. Their steps are read as six plucked columns in ONE query,
  # never as full records, because this runs after every autosave.
  test "a large closure costs a bounded number of queries and loads no foreign records" do
    shared = Workflow.create!(title: "Verify identity", user: @user, status: "draft")
    Steps::Question.create!(workflow: shared, position: 0, title: "Verified?", question: "Verified?",
                            answer_type: "yes_no", variable_name: "verified")
    5.times do |i|
      caller_wf = Workflow.create!(title: "Caller #{i}", user: @user, status: "draft")
      4.times { |n| Steps::Message.create!(workflow: caller_wf, position: n, title: "Say #{i}-#{n}") }
      Steps::SubFlow.create!(workflow: caller_wf, position: 9, title: "verify",
                             sub_flow_workflow_id: shared.id, sub_flow_returns: true)
    end
    Steps::SubFlow.create!(workflow: @workflow, position: 0, title: "verify",
                           sub_flow_workflow_id: shared.id, sub_flow_returns: true)

    steps = @workflow.reload.steps.includes(transitions: :target_step).to_a
    queries = count_queries { WorkflowVariableCheck.call(@workflow, steps) }

    assert_operator queries, :<=, 8, "two per closure level plus one pluck — not one per workflow"
  end

  # Most workflows name no variable anywhere — every shipped template among
  # them — and those must not pay for the sub-flow closure walk.
  test "a workflow with nothing to check runs no closure queries" do
    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "billing", position: 0)

    steps = @workflow.reload.steps.includes(transitions: :target_step).to_a
    sql = []
    counter = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      WorkflowVariableCheck.call(@workflow, steps)
    end

    assert_empty sql.grep(/sub_flow_workflow_id|sub_flow_returns/), "the closure was walked for nothing"
  end

  # --- jumps ------------------------------------------------------------------
  # StepResolver#check_jumps runs BEFORE transitions, so an unset variable in a
  # jump is the same defect one step earlier. No builder UI writes a jump and the
  # strict dialect refuses them, but the lenient JSON/YAML import preserves them
  # and a non-strict export writes them back out, so they exist in real data.

  test "an Action jump testing a variable nothing sets is reported" do
    q = question(variable_name: "reason")
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Look it up",
                                   jumps: [{ "condition" => "tier == 'gold'", "next_step_id" => SecureRandom.uuid }])
    Transition.create!(step: q, target_step: action, position: 0)
    Transition.create!(step: action, target_step: resolve(position: 2), position: 0)

    findings = check

    assert_equal([[action.uuid, :undefined_variable, ["tier"]]],
                 findings.map { |f| [f.step_uuid, f.code, f.variables] })
  end

  test "a jump testing a variable a step does set is not reported" do
    q = question(variable_name: "tier")
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Look it up",
                                   jumps: [{ "condition" => "tier == 'gold'", "next_step_id" => SecureRandom.uuid }])
    Transition.create!(step: q, target_step: action, position: 0)
    Transition.create!(step: action, target_step: resolve(position: 2), position: 0)

    assert_empty check
  end

  # check_jumps special-cases this literal on an Action; it names no variable.
  test "an Action's `completed` jump is not reported" do
    action = Steps::Action.create!(workflow: @workflow, position: 0, title: "Do it",
                                   jumps: [{ "condition" => "completed", "next_step_id" => SecureRandom.uuid }])
    Transition.create!(step: action, target_step: resolve, position: 0)

    assert_empty check
  end

  # On a Question the runtime compares the jump condition to the step's own
  # answer AS A STRING — `current_answer.to_s == jump_condition.to_s` — so text
  # that looks like an expression is a literal there, and naming it a variable
  # would be inventing a finding.
  test "a Question's jump is a literal, never scanned for a variable" do
    q = question(variable_name: "reason")
    q.update!(jumps: [{ "condition" => "tier == 'gold'", "next_step_id" => SecureRandom.uuid }])
    Transition.create!(step: q, target_step: resolve, position: 0)

    assert_empty check
  end

  # --- bare conditions -------------------------------------------------------

  test "a bare value condition names no variable and is skipped" do
    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "billing", position: 0)

    assert_empty check, "a bare condition matches the step's own answer"
  end

  # --- sub-flows, both directions -------------------------------------------

  test "a callee may read variables only its caller sets" do
    parent = Workflow.create!(title: "Caller", user: @user, status: "draft")
    pq = Steps::Question.create!(workflow: parent, position: 0, title: "Tier?",
                                 question: "Tier?", answer_type: "text", variable_name: "account_tier")
    sub = Steps::SubFlow.create!(workflow: parent, position: 1, title: "Run the child",
                                 sub_flow_workflow_id: @workflow.id, sub_flow_returns: true)
    Transition.create!(step: pq, target_step: sub, position: 0)

    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "account_tier == 'gold'", position: 0)

    assert_empty check, "a child is seeded with its caller's whole bag"
  end

  test "a caller may read variables only its returning child sets" do
    child = Workflow.create!(title: "Callee", user: @user, status: "draft")
    Steps::Question.create!(workflow: child, position: 0, title: "Outcome?",
                            question: "Outcome?", answer_type: "text", variable_name: "repair_ok")

    sub = Steps::SubFlow.create!(workflow: @workflow, position: 0, title: "Ask the child",
                                 sub_flow_workflow_id: child.id, sub_flow_returns: true)
    Transition.create!(step: sub, target_step: resolve, condition: "repair_ok == 'yes'", position: 0)

    assert_empty check, "a returning sub-flow merges every child key back into the parent"
  end

  test "inheritance is transitive, so A -> B -> C sees A's variables" do
    a = Workflow.create!(title: "A", user: @user, status: "draft")
    b = Workflow.create!(title: "B", user: @user, status: "draft")
    Steps::Question.create!(workflow: a, position: 0, title: "Tier?", question: "Tier?",
                            answer_type: "text", variable_name: "account_tier")
    Steps::SubFlow.create!(workflow: a, position: 1, title: "into B",
                           sub_flow_workflow_id: b.id, sub_flow_returns: true)
    Steps::SubFlow.create!(workflow: b, position: 0, title: "into C",
                           sub_flow_workflow_id: @workflow.id, sub_flow_returns: true)

    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "account_tier == 'gold'", position: 0)

    assert_empty check, "C receives what B had, and B had everything A had"
  end

  test "a cycle of sub-flows terminates" do
    other = Workflow.create!(title: "Other", user: @user, status: "draft")
    Steps::SubFlow.create!(workflow: @workflow, position: 0, title: "out",
                           sub_flow_workflow_id: other.id, sub_flow_returns: true)
    Steps::SubFlow.create!(workflow: other, position: 0, title: "back",
                           sub_flow_workflow_id: @workflow.id, sub_flow_returns: true)

    q = question(variable_name: "reason")
    Transition.create!(step: q, target_step: resolve, condition: "nothing_sets_this == 'x'", position: 0)

    findings = nil
    assert_nothing_raised { findings = check }
    assert_equal [:undefined_variable], findings.map(&:code), "and still reports the real gap"
  end

  # --- what a real template does, and does not, expose ------------------------

  # Worth stating because it is surprising and it narrows the risk this whole
  # check was built for: the shipped templates branch on BARE value conditions
  # ("billing"), not expressions ("call_reason == 'billing'"). A bare condition
  # is matched against the source step's own answer through
  # `results[variable_name] || results[title]`, and process_question_step writes
  # BOTH. So renaming the variable on a template-built workflow breaks nothing.
  test "a template as shipped is rename-proof, because its conditions are bare" do
    apply_template("guided_decision")
    question = @workflow.reload.steps.find { |s| s.is_a?(Steps::Question) && s.variable_name.present? }

    assert_empty question.transitions.filter_map { |t| t.condition.to_s[WorkflowVariableCheck::CONDITION_VARIABLE, 1] },
                 "precondition: the template names no variable in any condition"

    question.update!(variable_name: "why_they_called")

    assert_empty check, "a bare condition still matches through results[title]"
  end

  # The path that IS exposed. The builder's condition editor has a sentence
  # builder (see WorkflowsHelper#condition_sentence_variables) that writes the
  # expression form, so a manager who uses it and later renames the variable
  # gets branches that cannot fire — with no other signal than this one.
  test "a sentence-built condition on a template is broken by a rename, and is reported" do
    apply_template("guided_decision")
    question = @workflow.reload.steps.find { |s| s.is_a?(Steps::Question) && s.variable_name.present? }
    branch = question.transitions.first
    branch.update!(condition: "#{question.variable_name} == '#{branch.condition}'")

    assert_empty check, "precondition: sound while the names agree"

    question.update!(variable_name: "why_they_called")
    findings = check.select { |f| f.code == :undefined_variable }

    assert_equal [question.uuid], findings.map(&:step_uuid)
    assert_includes findings.first.variables, "call_reason"
  end

  # Copy is read by someone who is already unsure whether they broke something,
  # so "sets it" about two variables is a small thing that reads as carelessness.
  test "the interpolation message agrees in number" do
    q = question(variable_name: "reason", title: "Ask {{one}}")
    Transition.create!(step: q, target_step: resolve, position: 0)
    single = WorkflowHealthCheck.call(@workflow.reload).issues.values.flatten
                                .find { |i| i[:code] == :undefined_interpolation }
    assert_match(/sets it\./, single[:message])

    q.update!(title: "Ask {{one}} and {{two}}")
    double = WorkflowHealthCheck.call(@workflow.reload).issues.values.flatten
                                .find { |i| i[:code] == :undefined_interpolation }
    assert_match(/sets them\./, double[:message])
  end

  # --- cost ------------------------------------------------------------------

  test "rich text is preloaded, so the scan does not cost a query per step" do
    q = question(variable_name: "reason")
    previous = q
    6.times do |i|
      message = Steps::Message.create!(workflow: @workflow, position: i + 1, title: "Say #{i}")
      message.content = "<p>Body #{i}</p>"
      message.save!
      Transition.create!(step: previous, target_step: message, position: 0)
      previous = message
    end
    Transition.create!(step: previous, target_step: resolve(position: 99), position: 0)

    steps = @workflow.reload.steps.includes(transitions: :target_step).to_a
    queries = count_queries { WorkflowVariableCheck.call(@workflow, steps) }

    assert_operator queries, :<=, 8,
                    "six Message bodies must not cost six queries — see preload_rich_text"
  end
end
