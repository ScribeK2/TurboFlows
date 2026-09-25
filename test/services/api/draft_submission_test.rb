require "test_helper"

class Api::DraftSubmissionTest < ActiveSupport::TestCase
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "t", scopes: %w[read draft], expires_in_days: 7)
  end

  test "validate writes nothing and reports findings" do
    assert_no_difference("Workflow.count") do
      report = submission(dangling_document).validate
      assert_not report[:valid]
      assert_equal "dangling_transition_target", report[:errors].first[:code]
    end
  end

  test "create makes a draft owned by the user and stamped with the token" do
    result = submission(valid_document).create
    assert_predicate result, :created?
    workflow = result.workflows.sole
    assert_predicate workflow, :draft?
    assert_equal @editor, workflow.user
    assert_equal @token, workflow.api_token
  end

  test "the finding's message is enough to fix the document" do
    refused = submission(dangling_document).create
    assert_not refused.created?
    finding = refused.errors.first
    assert_equal "dangling_transition_target", finding[:code]
    assert_match(/"nowhere"/, finding[:message])

    # Do what the message says: point the transition at a step that exists.
    fixed = JSON.parse(dangling_document)
    fixed["workflows"][0]["steps"][0]["transitions"][0]["target_id"] = "done"
    assert_predicate submission(fixed.to_json).create, :created?
  end

  test "a refusal at the cap runs one COUNT query for outstanding drafts, not several" do
    fill_to(Api::DraftSubmission::DRAFT_LIMIT)
    count = count_queries { submission(valid_document).create }
    assert_equal 1, count, "expected #outstanding to be memoized within the call"
  end

  test "at the cap, create is refused; delete one and it succeeds" do
    fill_to(Api::DraftSubmission::DRAFT_LIMIT)
    refused = submission(valid_document).create
    assert_equal "api_draft_limit", refused.errors.sole[:code]

    Workflow.created_via_api.where(user: @editor).first.destroy!
    assert_predicate submission(valid_document).create, :created?
  end

  test "a bundle that would cross the cap is refused whole" do
    fill_to(Api::DraftSubmission::DRAFT_LIMIT - 1)
    assert_no_difference("Workflow.count") do
      refused = submission(valid_document(count: 2)).create
      assert_equal "api_draft_limit", refused.errors.sole[:code]
    end
  end

  test "a commit that fails inside WorkflowImporter is a refused_at_commit finding, and nothing is written" do
    original_call = WorkflowImporter.instance_method(:call)
    failed = WorkflowImporter::Result.new(success: false, workflows: [], errors: ["the write failed"],
                                          warnings: [], incomplete_steps_count: 0)
    WorkflowImporter.define_method(:call) { failed }

    assert_no_difference("Workflow.count") do
      refused = submission(valid_document).create
      assert_not refused.created?
      finding = refused.errors.sole
      assert_equal "refused_at_commit", finding[:code]
      assert_equal "the write failed", finding[:message]
    end
  ensure
    WorkflowImporter.define_method(:call, original_call)
  end

  test "malformed JSON is a malformed_json finding, not an exception" do
    assert_equal "malformed_json", submission("{nope").create.errors.first[:code]
    assert_equal "malformed_json", submission("").create.errors.first[:code]
  end

  # The MCP cap (Api::DraftBodyGuard::MCP_MAX_BYTES) has 1 MB of headroom over
  # WorkflowImporter::MAX_IMPORT_BYTES for the JSON-RPC envelope, so a document
  # between the two sizes reaches here without ever being refused by REST's
  # cap -- DraftSubmission is the one seam both faces call, so it has to
  # refuse it too, or MCP would accept documents REST won't.
  test "validate refuses content over the import cap without running the validator" do
    oversized = "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1)
    report = submission(oversized).validate
    assert_not report[:valid]
    assert_equal "payload_too_large", report[:errors].sole[:code]
  end

  test "create refuses content over the import cap and writes nothing" do
    oversized = "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1)
    assert_no_difference("Workflow.count") do
      refused = submission(oversized).create
      assert_equal "payload_too_large", refused.errors.sole[:code]
    end
  end

  private

  def submission(content) = Api::DraftSubmission.new(user: @editor, api_token: @token, content:)

  def valid_document(count: 1)
    { schema_version: "1", workflows: Array.new(count) do |i|
      { title: "Draft #{i} #{SecureRandom.hex(2)}",
        steps: [{ id: "done", type: "resolve", title: "Done", resolution_type: "success" }] }
    end }.to_json
  end

  def dangling_document
    { schema_version: "1", workflows: [{
      title: "Dangling #{SecureRandom.hex(2)}",
      steps: [
        { id: "act", type: "action", title: "Do it", instructions: "Do it",
          transitions: [{ target_id: "nowhere" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }] }.to_json
  end

  def fill_to(count)
    count.times { Workflow.create!(title: "Filler #{SecureRandom.hex(3)}", user: @editor, status: "draft", api_token: @token) }
  end
end
