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

  # Step UUIDs and timestamps legitimately differ between the two documents;
  # everything else — including title, which round-trips identically — must
  # match exactly.
  def normalize(document)
    doc = document.except("exported_at", "start_node_uuid")
    doc["steps"] = doc["steps"].map do |step|
      step.except("id").merge(
        "transitions" => Array(step["transitions"]).map { |t| t.except("target_uuid") }
      )
    end
    doc
  end
end
