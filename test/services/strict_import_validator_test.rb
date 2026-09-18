require "test_helper"

class StrictImportValidatorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "strict-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  setup do
    @group = Group.create!(name: "Strict Group #{SecureRandom.hex(3)}")
    UserGroup.create!(user: @user, group: @group)
  end

  teardown do
    User.where("email LIKE ?", "strict-test-%").destroy_all
    Group.where("name LIKE ?", "Strict Group %").destroy_all
    Workflow.where("title LIKE ?", "SF Target %").destroy_all
  end

  test "a file with schema_version is the strict dialect" do
    assert StrictImportValidator.strict?('{"schema_version":"1","workflows":[]}')
  end

  test "a file without schema_version is not" do
    assert_not StrictImportValidator.strict?('{"title":"Legacy","steps":[]}')
  end

  test "non-JSON is not the strict dialect" do
    assert_not StrictImportValidator.strict?("workflow_title,step_number\nA,1\n")
  end

  test "an unsupported schema_version is a hard error naming what is supported" do
    report = validate({ schema_version: "99", workflows: [] })

    assert_not report.valid?
    error = report.errors.first
    assert_equal "unsupported_schema_version", error[:code]
    assert_equal "schema_version", error[:path]
    assert_equal "99", error[:value]
    assert_equal [ImportSchemaGenerator::SCHEMA_VERSION], error[:expected]
  end

  test "a missing workflows array is an envelope error" do
    report = validate({ schema_version: "1" })

    assert_not report.valid?
    assert_equal "envelope_invalid", report.errors.first[:code]
  end

  test "two workflows sharing a title are refused, because a sub_flow target is matched by title" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow, minimal_workflow] })

    assert_not report.valid?
    assert_equal "duplicate_workflow_title", report.errors.first[:code]
    assert_equal "workflows[1].title", report.errors.first[:path],
                 "the second one is the duplicate, and the path has to say which"
  end

  test "more workflows than a file may carry is refused" do
    too_many = Array.new(ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE + 1) do |i|
      minimal_workflow.merge(title: "Bundle Workflow #{i}")
    end
    report = validate({ schema_version: "1", workflows: too_many })

    assert_not report.valid?
    assert_equal "envelope_invalid", report.errors.first[:code]
    assert_match(/at most/, report.errors.first[:message])
  end

  test "select choices that are not label/value pairs are refused" do
    # `["IVR", "Link"]` is a plausible shape and the first version of this guard
    # accepted it: `scenarios/_form_step` then reads `opt["value"]` off a String,
    # which is String#[] answering nil, so every option renders blank. Checking
    # only for a non-empty Array let the unanswerable dropdown back in.
    report = validate({ schema_version: "1", workflows: [minimal_workflow.merge(
      steps: [
        { id: "f", type: "form", title: "F",
          options: [{ name: "m", label: "M", field_type: "select",
                      select_options: %w[IVR Link] }],
          transitions: [{ target_id: "done" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    )] })

    assert_not report.valid?
    assert_equal "missing_select_options", report.errors.first[:code]
  end

  test "a select choice missing its value is refused" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow.merge(
      steps: [
        { id: "f", type: "form", title: "F",
          options: [{ name: "m", label: "M", field_type: "select",
                      select_options: [{ label: "IVR" }] }],
          transitions: [{ target_id: "done" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    )] })

    assert_not report.valid?
    assert_equal "missing_select_options", report.errors.first[:code]
  end

  test "well-formed select choices are accepted" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow.merge(
      steps: [
        { id: "f", type: "form", title: "F",
          options: [{ name: "m", label: "M", field_type: "select",
                      select_options: [{ label: "IVR", value: "ivr" }] }],
          transitions: [{ target_id: "done" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    )] })

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "a file carrying exactly the maximum number of workflows is accepted" do
    at_limit = Array.new(ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE) do |i|
      minimal_workflow.merge(title: "Bundle Workflow #{i}")
    end
    report = validate({ schema_version: "1", workflows: at_limit })

    assert_predicate report, :valid?, report.errors.inspect
    assert_equal ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE, report.workflows_data.size
  end

  test "a non-string workflow title is refused" do
    # A JSON `true` compares as "true" everywhere in the validator and is cast to
    # "t" by ActiveModel on save, so an in-bundle sub_flow target matched here and
    # bound to nothing at import time — with the import reporting success.
    [true, 42, %w[a b], { "x" => 1 }].each do |bad|
      report = validate({ schema_version: "1", workflows: [minimal_workflow.merge(title: bad)] })

      assert_not report.valid?, "#{bad.inspect} should be refused"
      assert_equal "invalid_workflow_title", report.errors.first[:code]
    end
  end

  test "an unknown workflow-level field is refused rather than ignored" do
    report = validate({ schema_version: "1",
                        workflows: [minimal_workflow.merge(start_step: "done")] })

    assert_not report.valid?,
               "a misspelled start_step_id used to be dropped in silence"
    assert_equal "unknown_field", report.errors.first[:code]
    assert_equal "workflows[0].start_step", report.errors.first[:path]
  end

  test "every documented workflow field is still accepted" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow.merge(
      description: "d", start_step_id: "done", tags: ["t"]
    )] })

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "an empty workflows array is refused" do
    report = validate({ schema_version: "1", workflows: [] })

    assert_not report.valid?
    assert_equal "envelope_invalid", report.errors.first[:code]
  end

  # The published schema says every form field requires `name` and `label`, and
  # the agent prompt is built from that schema — but the validator checked only a
  # select's choices. A field with no name writes its answer under the key ""
  # and a field with no label renders an unlabelled input, and both imported.
  test "a form field with a blank name or label is refused, at the field's own path" do
    report = validate(document_with(steps: [
                                      { id: "f", type: "form", title: "F",
                                        options: [{ name: "", label: "Callback number", field_type: "text" },
                                                  { name: "account", label: " ", field_type: "text" }],
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    missing = report.errors.select { |e| e[:code] == "missing_required_field" }
    assert_equal ["workflows[0].steps[0].options[0].name", "workflows[0].steps[0].options[1].label"],
                 missing.pluck(:path)
  end

  test "a form field carrying both name and label is accepted" do
    report = validate(document_with(steps: [
                                      { id: "f", type: "form", title: "F",
                                        options: [{ name: "callback", label: "Callback number", field_type: "text" }],
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_empty(report.errors.select { |e| e[:code] == "missing_required_field" })
  end

  test "malformed JSON is reported, not raised" do
    report = StrictImportValidator.new(user: @user, content: "{ nope").validate

    assert_not report.valid?
    assert_equal "malformed_json", report.errors.first[:code]
  end

  test "a minimal valid file passes" do
    report = validate({ schema_version: "1", workflows: [minimal_workflow] })

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "an unknown step type is refused with the valid list" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "decision", title: "Branch", transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "unknown_step_type" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].type", error[:path]
    assert_equal "decision", error[:value]
    assert_equal Workflow::VALID_STEP_TYPES, error[:expected]
  end

  test "a duplicate step id is refused" do
    report = validate(document_with(steps: [
                                      { id: "dup", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      { id: "dup", type: "message", title: "Two", content: "<p>b</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "duplicate_step_id" }
    assert_not_nil error
    assert_equal "workflows[0].steps[1].id", error[:path]
    assert_equal "dup", error[:value]
  end

  test "a missing step id is refused" do
    report = validate(document_with(steps: [
                                      { type: "message", title: "No id", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_includes report.errors.pluck(:code), "missing_step_id"
  end

  test "a step id with illegal characters is refused" do
    report = validate(document_with(steps: [
                                      { id: "not a slug!", type: "message", title: "Bad id", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "invalid_step_id" }
    assert_not_nil error
    assert_equal "not a slug!", error[:value]
  end

  test "an unknown field is refused rather than dropped" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "Extra", content: "<p>a</p>",
                                        colour: "blue", transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "unknown_field" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].colour", error[:path]
  end

  test "a field with no builder UI is refused with an explanation" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "action", title: "Jumper", instructions: "<p>a</p>",
                                        jumps: [{ condition: "x == '1'", next_step_id: "done" }],
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "excluded_field" }
    assert_not_nil error
    assert_match(/cannot be edited/, error[:message])
  end

  test "a missing required field for the type is refused" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "question", title: "No question text",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "missing_required_field" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].question", error[:path]
  end

  test "a non-resolve step without transitions is refused, not auto-wired" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "Dangling", content: "<p>a</p>" },
                                      resolve_step
                                    ]))

    assert_includes report.errors.pluck(:code), "missing_transitions"
  end

  test "a resolve step with transitions is refused" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      { id: "done", type: "resolve", title: "Done", resolution_type: "success",
                                        transitions: [{ target_id: "s1" }] }
                                    ]))

    assert_includes report.errors.pluck(:code), "unexpected_transitions"
  end

  test "a transition to a nonexistent step is refused, not silently dropped" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "nowhere" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "dangling_transition_target" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].transitions[0].target_id", error[:path]
    assert_equal "nowhere", error[:value]
  end

  test "an enum value outside the model's list is refused" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "question", title: "Q", question: "Which?",
                                        answer_type: "telepathy", transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "invalid_enum_value" }
    assert_not_nil error
    assert_equal Steps::Question::VALID_ANSWER_TYPES, error[:expected]
  end

  test "a blank workflow title is caught by the dry run, not at commit time" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1", workflows: [{ title: "", steps: [resolve_step] }]
    }.to_json).validate

    assert_not report.valid?
    error = report.errors.find { |e| e[:code] == "invalid_workflow_title" }
    assert_not_nil error
    assert_equal "workflows[0].title", error[:path]
  end

  test "an over-long workflow title is caught by the dry run" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1", workflows: [{ title: "x" * 256, steps: [resolve_step] }]
    }.to_json).validate

    assert_not report.valid?
    assert_includes report.errors.pluck(:code), "invalid_workflow_title"
  end

  test "a valid file's transitions are handed on as target_uuid" do
    report = validate(document_with(steps: [
                                      { id: "s1", type: "message", title: "One", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_equal "done", report.workflow_data["steps"][0]["transitions"][0]["target_uuid"]
  end

  # A loop is legal since the escapability rule replaced the acyclic check — what
  # is refused is a loop with no way out. These two tests are the pair that pins
  # that distinction.
  test "a retry loop is accepted" do
    report = validate(document_with(steps: [
                                      { id: "ask", type: "question", title: "Fixed?", question: "Is it fixed?",
                                        variable_name: "fixed",
                                        transitions: [{ target_id: "done", condition: "fixed == 'yes'" },
                                                      { target_id: "retry" }] },
                                      { id: "retry", type: "action", title: "Try again", instructions: "<p>Retry.</p>",
                                        transitions: [{ target_id: "ask" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "a loop with no way out is refused" do
    report = validate(document_with(steps: [
                                      { id: "a", type: "message", title: "A", content: "<p>a</p>",
                                        transitions: [{ target_id: "b" }] },
                                      { id: "b", type: "message", title: "B", content: "<p>b</p>",
                                        transitions: [{ target_id: "a" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "graph_invalid" }
    assert_not_nil error
    assert_equal "no_path_to_resolve", error[:value]
  end

  test "an unreachable step is refused" do
    report = validate(document_with(steps: [
                                      { id: "start", type: "message", title: "Start", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      { id: "island", type: "message", title: "Unreachable", content: "<p>b</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_includes report.errors.pluck(:value), "unreachable_step"
  end

  test "a valid graph passes" do
    report = validate(document_with(steps: [
                                      { id: "start", type: "message", title: "Start", content: "<p>a</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "a compound condition is refused with the supported forms" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Tier?", question: "Which tier?",
                                        variable_name: "tier",
                                        transitions: [{ target_id: "done", condition: "tier == 'gold' && region == 'EU'" }] },
                                      resolve_step
                                    ]))

    error = report.errors.find { |e| e[:code] == "invalid_condition_syntax" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].transitions[0].condition", error[:path]
    assert_includes error[:expected], "var == 'value'"
  end

  test "a decimal comparison is refused, because ConditionEvaluator matches whole numbers" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Score?", question: "Score?",
                                        variable_name: "score", answer_type: "number",
                                        transitions: [{ target_id: "done", condition: "score > 3.5" }] },
                                      resolve_step
                                    ]))

    assert_includes report.errors.pluck(:code), "invalid_condition_syntax"
  end

  test "a supported condition passes" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Tier?", question: "Which tier?",
                                        variable_name: "tier",
                                        transitions: [{ target_id: "done", condition: "tier == 'gold'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "a condition on a variable nothing defines is a warning, not an error" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Tier?", question: "Which tier?",
                                        variable_name: "tier",
                                        transitions: [{ target_id: "done", condition: "reegion == 'EU'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    warning = report.warnings.find { |w| w[:code] == "undefined_variable" }
    assert_not_nil warning
    assert_equal "reegion", warning[:value]
  end

  test "an interpolated variable nothing defines is a warning" do
    report = validate(document_with(steps: [
                                      { id: "m", type: "message", title: "Greeting",
                                        content: "<p>Hello {{custmer_name}}</p>",
                                        transitions: [{ target_id: "done" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    assert_includes report.warnings.pluck(:value), "custmer_name"
  end

  test "a condition comparing against a value the question does not offer is a warning" do
    report = validate(document_with(steps: [
                                      { id: "q", type: "question", title: "Down?", question: "Is it down?",
                                        answer_type: "multiple_choice", variable_name: "down",
                                        options: [{ label: "Yes", value: "true" }, { label: "No", value: "false" }],
                                        transitions: [{ target_id: "done", condition: "down == 'yes'" }] },
                                      resolve_step
                                    ]))

    assert_predicate report, :valid?, report.errors.inspect
    warning = report.warnings.find { |w| w[:code] == "unmatched_option_value" }
    assert_not_nil warning
    assert_match(/true, false/, warning[:message])
  end

  test "an unknown group is an error on the strict report" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [{ title: "Placed", groups: ["No Such Group"], steps: [resolve_step] }]
    }.to_json).validate

    assert_not report.valid?
    error = report.errors.find { |e| e[:code] == "unknown_group" }
    assert_not_nil error
    assert_equal "workflows[0].groups[0]", error[:path]
  end

  test "an Uncategorized group is a warning on the strict report, not an error" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [{ title: "Old Export", groups: ["Uncategorized"], steps: [resolve_step] }]
    }.to_json).validate

    assert_predicate report, :valid?, report.errors.inspect
    warning = report.warnings.find { |w| w[:code] == "retired_group" }
    assert_not_nil warning
    assert_equal "workflows[0].groups[0]", warning[:path]
  end

  test "a nested group named by itself is accepted on the strict report" do
    child = Group.create!(name: "Strict Nested #{SecureRandom.hex(3)}", parent: @group)
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [{ title: "Placed", groups: [child.name], steps: [resolve_step] }]
    }.to_json).validate

    assert_predicate report, :valid?, report.errors.inspect
    assert_equal [child.id], report.placement.resolve.group_ids
  ensure
    child&.destroy
  end

  test "a valid file carries its resolved placement on the report" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [{ title: "Placed", groups: [@group.name], tags: ["billing"],
                    steps: [resolve_step] }]
    }.to_json).validate

    assert_predicate report, :valid?, report.errors.inspect
    assert_equal [@group.id], report.placement.resolve.group_ids
  end

  test "a sub_flow title resolves to the published workflow's id" do
    target = @user.workflows.create!(title: "SF Target #{SecureRandom.hex(3)}",
                                     status: "published")

    report = validate_subflow(target.title)

    assert_predicate report, :valid?, report.errors.inspect
    step = report.workflow_data["steps"].find { |s| s["type"] == "sub_flow" }
    assert_equal target.id, step["target_workflow_id"]
    assert_nil step["target_workflow_title"]
  end

  test "a sub_flow naming no workflow at all is a hard error" do
    report = validate_subflow("SF Target Nonexistent Nowhere")

    assert_not report.valid?
    error = report.errors.find { |e| e[:code] == "unknown_sub_flow_target" }
    assert_not_nil error
    assert_equal "workflows[0].steps[0].target_workflow_title", error[:path]
  end

  # Distinct from "no such workflow": slice 1 made every import land as a draft,
  # so "import A, then import B whose sub_flow targets A" now fails where it used
  # to work. Telling the user it does not exist would send them off to re-author a
  # workflow they already have.
  test "a sub_flow naming a draft says so, rather than claiming it does not exist" do
    draft = @user.workflows.create!(title: "SF Target #{SecureRandom.hex(3)}", status: "draft")

    report = validate_subflow(draft.title)

    assert_not report.valid?
    error = report.errors.find { |e| e[:code] == "sub_flow_target_not_published" }
    assert_not_nil error, report.errors.inspect
    assert_match(/publish/i, error[:message])
  end

  test "a sub_flow title matching two published workflows is a hard error" do
    title = "SF Target #{SecureRandom.hex(3)}"
    2.times { @user.workflows.create!(title:, status: "published") }

    report = validate_subflow(title)

    assert_not report.valid?
    assert_includes report.errors.pluck(:code), "ambiguous_sub_flow_target"
  end

  test "a published workflow the importer cannot see is not a valid sub_flow target" do
    stranger = User.create!(
      email: "strict-test-stranger-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    hidden = stranger.workflows.create!(title: "SF Target #{SecureRandom.hex(3)}",
                                        status: "published")
    Group.create!(name: "Strict Group #{SecureRandom.hex(3)}").tap do |g|
      hidden.replace_groups!([g.id])
    end

    report = validate_subflow(hidden.title)

    assert_not report.valid?
    assert_includes report.errors.pluck(:code), "unknown_sub_flow_target"
    assert_not_includes report.errors.pluck(:message).join, hidden.id.to_s
  end

  test "another user's draft does not produce the publish-it-first hint" do
    stranger = User.create!(
      email: "strict-test-stranger-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    theirs = stranger.workflows.create!(title: "SF Target #{SecureRandom.hex(3)}", status: "draft")

    report = validate_subflow(theirs.title)

    assert_not report.valid?
    assert_includes report.errors.pluck(:code), "unknown_sub_flow_target"
    assert_not_includes report.errors.pluck(:code), "sub_flow_target_not_published"
  end

  # Placement does not depend on the steps, so a file with both kinds of problem
  # must report both at once rather than making the user fix one, re-upload, and
  # discover the other.
  test "a bad group is reported alongside structural errors, not after them" do
    report = StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [{ title: "Both Wrong", groups: ["No Such Group Here"], steps: [
        { id: "s1", type: "decision", title: "Bad type",
          transitions: [{ target_id: "done" }] },
        resolve_step
      ] }]
    }.to_json).validate

    codes = report.errors.pluck(:code)
    assert_includes codes, "unknown_step_type"
    assert_includes codes, "unknown_group"
  end

  private

  def validate(hash)
    StrictImportValidator.new(user: @user, content: hash.to_json).validate
  end

  def minimal_workflow
    {
      title: "Minimal",
      steps: [{ id: "done", type: "resolve", title: "Done", resolution_type: "success" }]
    }
  end

  def document_with(steps:)
    { schema_version: "1", workflows: [{ title: "Structural", steps: }] }
  end

  def resolve_step
    { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
  end

  def validate_subflow(target_title)
    StrictImportValidator.new(user: @user, content: {
      schema_version: "1",
      workflows: [{ title: "Sub Flow Host", steps: [
        { id: "sf", type: "sub_flow", title: "Hand off",
          target_workflow_title: target_title, transitions: [{ target_id: "done" }] },
        resolve_step
      ] }]
    }.to_json).validate
  end
end
