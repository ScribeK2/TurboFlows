require "test_helper"

class Api::Mcp::DraftToolsTest < ActiveSupport::TestCase
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "d", scopes: %w[read draft], expires_in_days: 7)
  end

  test "validate reports findings and writes nothing" do
    assert_no_difference("Workflow.count") do
      response = call(Api::Mcp::ValidateWorkflowDraft, document: dangling)
      assert_not response.error?, "a report is the answer, not a refusal"
      assert_not response.structured_content[:valid]
      assert_equal "dangling_transition_target", response.structured_content[:errors].first[:code]
    end
  end

  test "create refuses a broken document as an isError result naming the fix" do
    response = call(Api::Mcp::CreateWorkflowDraft, document: dangling)
    assert_predicate response, :error?
    finding = response.structured_content[:errors].first
    assert_equal "dangling_transition_target", finding[:code]
    assert_match(/"nowhere"/, finding[:message])
  end

  test "create makes a draft stamped with the token and returns its url" do
    response = call(Api::Mcp::CreateWorkflowDraft, document: valid)
    assert_not response.error?
    created = response.structured_content[:workflows].sole
    workflow = Workflow.find(created[:id])
    assert_predicate workflow, :draft?
    assert_equal @token, workflow.api_token
    assert_equal "http://example.test/workflows/#{workflow.id}", created[:url]
  end

  test "a document sent as a JSON string is treated exactly like the object" do
    response = call(Api::Mcp::CreateWorkflowDraft, document: JSON.generate(valid))
    assert_not response.error?
    assert_equal 1, response.structured_content[:workflows].size
  end

  test "a string that isn't JSON is a malformed_json finding, not an exception" do
    response = call(Api::Mcp::CreateWorkflowDraft, document: "{nope")
    assert_predicate response, :error?
    assert_equal "malformed_json", response.structured_content[:errors].first[:code]
  end

  test "a document over the import cap is refused before validation runs" do
    huge = { schema_version: "1", workflows: [{ title: "Huge",
                                                description: "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1),
                                                steps: [] }] }
    assert_no_difference("Workflow.count") do
      response = call(Api::Mcp::CreateWorkflowDraft, document: huge)
      assert_predicate response, :error?
      assert_equal "payload_too_large", response.structured_content[:errors].first[:code]
    end
  end

  test "a token that has lost the draft scope is refused and nothing is written" do
    @editor.update!(role: "user")
    assert_no_difference("Workflow.count") do
      response = call(Api::Mcp::CreateWorkflowDraft, document: valid)
      assert_predicate response, :error?
      assert_equal "insufficient_scope", response.structured_content[:errors].first[:code]
    end
  end

  test "validate_workflow_draft's own scope guard refuses a token that lost the draft scope" do
    @editor.update!(role: "user")
    assert_no_difference("Workflow.count") do
      response = call(Api::Mcp::ValidateWorkflowDraft, document: valid)
      assert_predicate response, :error?
      assert_equal "insufficient_scope", response.structured_content[:errors].first[:code]
    end
  end

  private

  def call(tool, **arguments)
    context = { user: @editor, api_token: @token.reload,
                catalog: Api::WorkflowCatalog.new(@editor, base_url: "http://example.test") }
    delivered = JSON.parse(JSON.generate(arguments), symbolize_names: true)
    tool.call(**delivered, server_context: context)
  end

  def valid
    { schema_version: "1", workflows: [{ title: "MCP #{SecureRandom.hex(2)}",
                                         steps: [{ id: "done", type: "resolve", title: "Done",
                                                   resolution_type: "success" }] }] }
  end

  def dangling
    { schema_version: "1", workflows: [{
      title: "Dangling #{SecureRandom.hex(2)}",
      steps: [
        { id: "act", type: "action", title: "Do it", instructions: "Do the thing.",
          transitions: [{ target_id: "nowhere" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }] }
  end
end
