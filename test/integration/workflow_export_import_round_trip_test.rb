require "test_helper"

# Export -> import -> export must produce an identical document. This is the one
# assertion that catches silent field loss across the whole import path, which is
# the failure this codebase has already been bitten by (see StepFieldMap).
class WorkflowExportImportRoundTripTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "round-trip-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @root = Group.create!(name: "RoundTrip #{SecureRandom.hex(2)}")
    @child = Group.create!(name: "RoundTrip Tier 2 #{SecureRandom.hex(2)}", parent: @root)
    Folder.create!(name: "Escalations", group: @child)
    UserGroup.create!(user: @user, group: @root)
    UserGroup.create!(user: @user, group: @child)
    sign_in @user
  end

  teardown do
    User.where("email LIKE ?", "round-trip-%").destroy_all
    # A single prefix catches both the root and the child: the child's name is
    # "RoundTrip Tier 2 #{hex}", so it always starts with "RoundTrip" too. That
    # matters because Group#children is `dependent: :nullify`, not :destroy — a
    # teardown that only matched the root would orphan the child instead of
    # removing it.
    Group.where("name LIKE ?", "RoundTrip%").destroy_all
    Tag.where(name: %w[billing tier-2]).destroy_all
  end

  # A workflow authored before select_options existed exports to a file the
  # strict validator now refuses. That is a deliberate, narrow break in the
  # "an exported file is a valid strict import file" guarantee in AGENTS.md:
  # such a select was ALWAYS a dropdown nobody could answer, so the alternative
  # is round-tripping a broken field silently. WorkflowHealthCheck flags it on
  # the step so an operator can fix it before exporting.
  test "a workflow with a choiceless select exports, and the strict path refuses it back" do
    workflow = Workflow.create!(title: "Legacy Select #{SecureRandom.hex(2)}",
                                user: @user, status: "draft")
    form = Steps::Form.create!(
      workflow: workflow, uuid: SecureRandom.uuid, position: 0, title: "Collect",
      options: [{ "name" => "method", "label" => "How paid", "field_type" => "select" }]
    )
    resolve = Steps::Resolve.create!(workflow: workflow, uuid: SecureRandom.uuid, position: 1,
                                     title: "Done", resolution_type: "success")
    Transition.create!(step: form, target_step: resolve, position: 0)
    workflow.update!(start_step: form)

    get workflow_export_path(workflow)
    assert_response :success
    exported = response.body

    report = StrictImportValidator.new(user: @user, content: exported).validate
    assert_not report.valid?, "the export carries a select with no choices"
    assert_equal ["missing_select_options"], report.errors.pluck(:code).uniq

    flagged = WorkflowHealthCheck.new(workflow.reload).call.issues[form.uuid]
    assert(flagged.any? { |i| i[:code] == :select_options_required },
           "the health panel is how an operator finds this before exporting")
  end

  # A fourth narrow break, and the builder makes it on purpose: a Form field row
  # autosaves before its name is typed (a refused save lost the edit). The export
  # carries the half-filled field and the strict path refuses it, because the
  # published schema has always required both keys.
  test "a form field with no name exports, and the strict path refuses it back" do
    workflow = Workflow.create!(title: "Half Field #{SecureRandom.hex(2)}", user: @user, status: "draft")
    form = Steps::Form.new(workflow: workflow, uuid: SecureRandom.uuid, position: 0, title: "Collect",
                           options: [{ "name" => "", "label" => "Callback number", "field_type" => "text" }])
    form.save!(validate: false)
    resolve = Steps::Resolve.create!(workflow: workflow, uuid: SecureRandom.uuid, position: 1,
                                     title: "Done", resolution_type: "success")
    Transition.create!(step: form, target_step: resolve, position: 0)
    workflow.update!(start_step: form)

    get workflow_export_path(workflow)
    assert_response :success

    report = StrictImportValidator.new(user: @user, content: response.body).validate
    assert_not report.valid?
    assert_equal ["missing_required_field"], report.errors.pluck(:code).uniq
    assert_match(/options\[0\]\.name\z/, report.errors.first[:path])

    flagged = WorkflowHealthCheck.new(workflow.reload).call.issues[form.uuid]
    assert(flagged.any? { |i| i[:code] == :form_field_incomplete },
           "the health panel is how an operator finds this before exporting")
  end

  # The same narrow break, for fields the builder saves blank on purpose. The
  # step panel lets a step autosave with no title or question text (a refused
  # save lost the edit), and the runner shows the title when the question is
  # blank, but the import schema requires both. The health check says so.
  test "a question with no title or text exports, and the strict path refuses it back" do
    workflow = Workflow.create!(title: "Blank Question #{SecureRandom.hex(2)}",
                                user: @user, status: "draft")
    question = Steps::Question.create!(workflow: workflow, uuid: SecureRandom.uuid, position: 0,
                                       title: "", question: nil, answer_type: "text")
    resolve = Steps::Resolve.create!(workflow: workflow, uuid: SecureRandom.uuid, position: 1,
                                     title: "Done", resolution_type: "success")
    Transition.create!(step: question, target_step: resolve, position: 0)
    workflow.update!(start_step: question)

    get workflow_export_path(workflow)
    assert_response :success

    report = StrictImportValidator.new(user: @user, content: response.body).validate
    assert_not report.valid?, "the export carries a question with no title or text"
    assert_equal ["missing_required_field"], report.errors.pluck(:code).uniq
    assert_equal %w[question title], report.errors.map { it[:path].split(".").last }.sort

    codes = WorkflowHealthCheck.new(workflow.reload).call.issues[question.uuid].pluck(:code)
    assert_includes codes, :title_required
    assert_includes codes, :question_text_required
  end

  test "a workflow whose select has real choices round-trips cleanly" do
    workflow = Workflow.create!(title: "Good Select #{SecureRandom.hex(2)}",
                                user: @user, status: "draft")
    form = Steps::Form.create!(
      workflow: workflow, uuid: SecureRandom.uuid, position: 0, title: "Collect",
      options: [{ "name" => "method", "label" => "How paid", "field_type" => "select",
                  "select_options" => [{ "label" => "IVR", "value" => "ivr" }] }]
    )
    resolve = Steps::Resolve.create!(workflow: workflow, uuid: SecureRandom.uuid, position: 1,
                                     title: "Done", resolution_type: "success")
    Transition.create!(step: form, target_step: resolve, position: 0)
    workflow.update!(start_step: form)

    get workflow_export_path(workflow)
    report = StrictImportValidator.new(user: @user, content: response.body).validate

    assert_predicate report, :valid?, report.errors.inspect
    reimported = report.workflows_data.first["steps"].find { |s| s["type"] == "form" }
    assert_equal [{ "label" => "IVR", "value" => "ivr" }],
                 reimported["options"].first["select_options"],
                 "the choices survive export and come back intact"
  end

  test "export includes the workflow's groups, folder and tags" do
    workflow = import_fixture

    get workflow_export_path(workflow)

    assert_response :success
    data = response.parsed_body["workflows"].first
    assert_equal ["#{@root.name} / #{@child.name}"], data["groups"]
    assert_equal "Escalations", data["folder"]
    assert_equal %w[billing tier-2], data["tags"].sort
  end

  test "an exported workflow is itself a valid strict import file" do
    workflow = import_fixture

    get workflow_export_path(workflow)

    document = response.parsed_body
    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, document["schema_version"]
    assert_equal 1, document["workflows"].length

    report = StrictImportValidator.new(user: @user, content: response.body).validate
    assert_predicate report, :valid?, report.errors.inspect
  end

  test "export, import, export produces an identical document" do
    workflow = import_fixture

    get workflow_export_path(workflow)
    first_export = response.parsed_body

    # The comparison below only proves the two exports agree with each other,
    # not that either is correct: a corruption the importer applies the same
    # way on both passes (e.g. every transition wired to the first step) would
    # still satisfy it. Anchor to the fixture's known-correct topology directly
    # — ask(0) branches to act(1) on billing and to done(2) otherwise, act(1)
    # falls through to done(2), and done(2) is terminal — so that kind of bug
    # fails here even though it can't fail the round-trip comparison.
    first_workflow = normalize(first_export)["workflows"].first
    topo = first_workflow["steps"].map { |s| Array(s["transitions"]).map { |t| t["target_id"] } }
    assert_equal [[1, 2], [2], []], topo
    assert_equal 0, first_workflow["start_step_id"]

    # An exported document is now a strict-dialect file, so re-importing it goes
    # through the strict path — which is the point: the app can produce a worked
    # example of its own format.
    report = StrictImportValidator.new(user: @user, content: response.body).validate
    assert_predicate report, :valid?, report.errors.inspect
    reimported = WorkflowImporter.new(@user, format: :json, content: response.body,
                                             strict_report: report).call
    assert_predicate reimported, :success?

    get workflow_export_path(reimported.workflow)
    second_export = response.parsed_body

    assert_equal normalize(first_export), normalize(second_export)
  end

  private

  def import_fixture
    content = {
      title: "Round Trip #{SecureRandom.hex(2)}",
      description: "A workflow that survives a round trip",
      groups: ["#{@root.name} / #{@child.name}"],
      folder: "Escalations",
      tags: %w[billing tier-2],
      steps: [
        { id: "ask", type: "question", title: "Which issue?", question: "Which issue?",
          answer_type: "multiple_choice", variable_name: "issue",
          options: [{ label: "Billing", value: "billing" }, { label: "Other", value: "other" }],
          transitions: [{ target_uuid: "act", condition: "issue == 'billing'" },
                        { target_uuid: "done" }] },
        { id: "act", type: "action", title: "Check the account",
          instructions: "<p>Open the account in <strong>Billing</strong>.</p>",
          transitions: [{ target_uuid: "done" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: content).call
    assert_predicate result, :success?
    result.workflow
  end

  # Step UUIDs can't be relied on literally either way: the importer preserves
  # an explicit id verbatim (uniqueness is scoped to workflow_id, so the same
  # string is fine in a different workflow) and mints a fresh one only when a
  # step arrives with none — so two documents may carry identical ids or
  # different ones, depending on what the source provided. Dropping them
  # outright would leave transition topology unchecked, and a regression that
  # wired every transition to the wrong target would pass silently. Instead,
  # map each uuid to the index of the step it names (steps are exported in a
  # stable position order) and compare indices, so topology survives the
  # comparison while the literal id values — stable or not — do not.
  # Step uuids are legitimately regenerated on import, so they cannot be compared
  # literally — but deleting them would leave only condition and label on each
  # transition, and an importer that wired every transition to the wrong step
  # would still pass. Map each uuid to the INDEX of the step it names instead, so
  # a rewired transition changes the compared document.
  def normalize(document)
    # deep_dup, not except: the rewrites below reach into workflows[0], which a
    # shallow copy shares with the caller's document. Without this, calling
    # normalize twice on the same export rewrites already-rewritten indices and
    # every target_id comes back nil.
    doc = document.deep_dup.except("exported_at")
    workflow = doc["workflows"].first
    steps = workflow["steps"]
    index_by_uuid = steps.each_with_index.to_h { |step, i| [step["id"], i] }

    workflow["start_step_id"] = index_by_uuid.fetch(workflow["start_step_id"], nil)
    workflow["steps"] = steps.map do |step|
      step.except("id").merge(
        "transitions" => Array(step["transitions"]).map do |t|
          t.merge("target_id" => index_by_uuid.fetch(t["target_id"], nil))
        end
      )
    end
    doc
  end
end
