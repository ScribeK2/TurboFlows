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

  test "export includes the workflow's groups, folder and tags" do
    workflow = import_fixture

    get workflow_export_path(workflow)

    assert_response :success
    data = response.parsed_body
    assert_equal ["#{@root.name} / #{@child.name}"], data["groups"]
    assert_equal "Escalations", data["folder"]
    assert_equal %w[billing tier-2], data["tags"].sort
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
    topo = normalize(first_export)["steps"].map { |s| s["transitions"].map { |t| t["target_uuid"] } }
    assert_equal [[1, 2], [2], []], topo
    assert_equal 0, normalize(first_export)["start_node_uuid"]

    reimported = WorkflowImporter.new(@user, format: :json, content: response.body).call
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
  def normalize(document)
    doc = document.except("exported_at")
    steps = doc["steps"]
    index_by_uuid = steps.each_with_index.to_h { |step, i| [step["id"], i] }

    doc["start_node_uuid"] = index_by_uuid.fetch(doc["start_node_uuid"], nil)
    doc["steps"] = steps.map do |step|
      step.except("id").merge(
        "transitions" => Array(step["transitions"]).map do |t|
          t.merge("target_uuid" => index_by_uuid.fetch(t["target_uuid"], nil))
        end
      )
    end
    doc
  end
end
