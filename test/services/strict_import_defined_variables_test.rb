require "test_helper"

# What counts as a variable "set" by a strict-dialect file.
#
# StrictImportValidator read `variable_name` and nothing else, so it warned on
# correct files. The runtime writes far more — ScenarioStepProcessor puts every
# step's title and every Form field name into the bag, a returning sub-flow merges its child's whole bag back into its caller,
# and ConditionEvaluator#lookup_value matches names case-insensitively and
# resolves the legacy name "answer". WorkflowVariableCheck learned all of this
# for the builder; this is the importer catching up, through the same module.
#
# It never refused an import — these are warnings — which is why nobody noticed.
# But the import page hands these warnings to an AI agent as things to fix, and
# an agent told a working branch is broken will "fix" it.
class StrictImportDefinedVariablesTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "strict-defined-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!",
                         role: "editor")
  end

  # Action output_fields also write names into the bag, but the strict dialect
  # refuses the field outright (ImportSchemaGenerator::EXCLUDED_FIELDS), so a
  # file naming one never reaches a warning. Nothing to catch up on there.

  test "a condition on a Form field name is not reported" do
    assert_empty undefined_in(steps: [
                                { id: "f", type: "form", title: "Collect",
                                  options: [{ name: "account_number", label: "Account number", field_type: "text" }],
                                  transitions: [{ target_id: "done", condition: "account_number == '42'" }] },
                                resolve_step
                              ])
  end

  test "a condition on a step title is not reported, because the runtime writes results[title]" do
    assert_empty undefined_in(steps: [
                                { id: "q", type: "question", title: "tier", question: "Which tier?", answer_type: "text",
                                  transitions: [{ target_id: "done", condition: "tier == 'gold'" }] },
                                resolve_step
                              ])
  end

  test "the legacy name `answer` is not reported" do
    assert_empty undefined_in(steps: [
                                { id: "q", type: "question", title: "Ready?", question: "Ready?", answer_type: "yes_no",
                                  transitions: [{ target_id: "done", condition: "answer == 'yes'" }] },
                                resolve_step
                              ])
  end

  test "a condition matches its variable whatever the case" do
    assert_empty undefined_in(steps: [
                                { id: "q", type: "question", title: "Why?", question: "Why?", answer_type: "text",
                                  variable_name: "reason",
                                  transitions: [{ target_id: "done", condition: "Reason == 'billing'" }] },
                                resolve_step
                              ])
  end

  test "an interpolation stays case-sensitive, because VariableInterpolator is" do
    warnings = undefined_in(steps: [
                              { id: "q", type: "question", title: "Why?", question: "Tell me {{Reason}}", answer_type: "text",
                                variable_name: "reason", transitions: [{ target_id: "done" }] },
                              resolve_step
                            ])

    assert_equal ["Reason"], warnings.pluck(:value)
  end

  # The warning said an unknown variable "will interpolate as empty". It does
  # not: VariableInterpolator leaves the match as written, so the agent reads
  # braces on a live call — and an AI agent fixing the file was being told the
  # failure is invisible when it is the opposite.
  test "the interpolation warning says what the runtime actually does" do
    warning = undefined_in(steps: [
                             { id: "q", type: "question", title: "Why?", question: "About {{plan}}", answer_type: "text",
                               transitions: [{ target_id: "done" }] },
                             resolve_step
                           ]).first

    assert_equal "{{plan}}", VariableInterpolator.interpolate("{{plan}}", { "other" => "x" }),
                 "precondition: an unknown variable is left as written, not blanked"
    assert_no_match(/empty/, warning[:message])
    assert_match(/braces/, warning[:message])
  end

  # --- both directions of a sub-flow ----------------------------------------

  test "a caller may test a variable only its returning child sets" do
    assert_empty undefined_in_bundle(returns: true)
  end

  test "a handoff never comes back, so its variables do not reach the caller" do
    warnings = undefined_in_bundle(returns: false)

    assert_equal ["repair_ok"], warnings.pluck(:value),
                 "sub_flow_returns: false is a tail call — nothing merges back"
  end

  # --- and it still says something ------------------------------------------

  test "a variable nothing sets is still reported" do
    warnings = undefined_in(steps: [
                              { id: "q", type: "question", title: "Why?", question: "Why?", answer_type: "text",
                                variable_name: "reason",
                                transitions: [{ target_id: "done", condition: "call_reason == 'billing'" }] },
                              resolve_step
                            ])

    assert_equal ["call_reason"], warnings.pluck(:value)
  end

  private

  def undefined_in(steps:)
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1", workflows: [{ title: "Defined #{SecureRandom.hex(2)}", steps: steps }]
    }.to_json).validate
    assert_predicate report, :valid?, report.errors.inspect
    report.warnings.select { |w| w[:code] == "undefined_variable" }
  end

  # A caller whose sub_flow step branches on `repair_ok`, which only the child sets.
  def undefined_in_bundle(returns:)
    sub = { id: "sf", type: "sub_flow", title: "Ask the child", target_workflow_title: "Child",
            sub_flow_returns: returns }
    sub[:transitions] = [{ target_id: "done", condition: "repair_ok == 'yes'" }] if returns
    caller_steps = returns ? [sub, resolve_step] : [caller_question, sub]

    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [
        { title: "Caller", steps: caller_steps },
        { title: "Child", steps: [
          { id: "cq", type: "question", title: "Did it work?", question: "Did it work?",
            answer_type: "yes_no", variable_name: "repair_ok", transitions: [{ target_id: "done" }] },
          resolve_step
        ] }
      ]
    }.to_json).validate
    assert_predicate report, :valid?, report.errors.inspect
    report.warnings.select { |w| w[:code] == "undefined_variable" && w[:path].start_with?("workflows[0]") }
  end

  # For the handoff case the caller needs a branch that tests the child's
  # variable BEFORE handing off, since a handoff step itself takes no transitions.
  def caller_question
    { id: "pre", type: "question", title: "Already fixed?", question: "Already fixed?",
      answer_type: "yes_no", variable_name: "already",
      transitions: [{ target_id: "sf", condition: "repair_ok == 'yes'" }, { target_id: "sf" }] }
  end

  def resolve_step
    { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
  end
end
