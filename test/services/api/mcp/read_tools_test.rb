require "test_helper"

class Api::Mcp::ReadToolsTest < ActiveSupport::TestCase
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @other = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "r", scopes: %w[read], expires_in_days: 7)
    @mine = Workflow.create!(title: "Refund dispute #{SecureRandom.hex(2)}", user: @editor, status: "draft")
    @theirs = Workflow.create!(title: "Theirs #{SecureRandom.hex(2)}", user: @other, status: "draft")
  end

  test "search_workflows returns visible summaries as structured content and text" do
    response = call(Api::Mcp::SearchWorkflows, query: "refund")
    assert_not response.error?
    data = response.structured_content
    assert_equal [@mine.id], data[:workflows].pluck(:id)
    assert_equal JSON.parse(response.content.first[:text], symbolize_names: true), data
  end

  test "search_workflows refuses an unknown group id as a catalog InvalidFilter tool result" do
    response = call(Api::Mcp::SearchWorkflows, group: 999_999)
    assert_predicate response, :error?
    assert_equal "invalid_filter", response.structured_content[:errors].first[:code]
  end

  test "get_workflow answers the strict document for a visible workflow" do
    response = call(Api::Mcp::GetWorkflow, id: @mine.id)
    assert_not response.error?
    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, response.structured_content.dig(:document, :schema_version)
  end

  test "get_workflow refuses someone else's draft exactly like a missing one" do
    hidden = call(Api::Mcp::GetWorkflow, id: @theirs.id)
    missing = call(Api::Mcp::GetWorkflow, id: 0)
    assert_predicate hidden, :error?
    assert_equal "not_found", hidden.structured_content[:errors].first[:code]
    assert_equal missing.structured_content, hidden.structured_content
  end

  test "get_workflow accepts an id sent as a numeric string, and refuses a non-numeric one cleanly" do
    assert_not call(Api::Mcp::GetWorkflow, id: @mine.id.to_s).error?
    refused = call(Api::Mcp::GetWorkflow, id: "twelve")
    assert_predicate refused, :error?
    assert_equal "not_found", refused.structured_content[:errors].first[:code]
  end

  test "get_workflow reads an id in base 10 only, never as octal or hex" do
    padded = call(Api::Mcp::GetWorkflow, id: "0#{@mine.id}")
    assert_not padded.error?, "expected the padded id to resolve: #{padded.structured_content.inspect}"
    assert_equal @mine.id, padded.structured_content[:id]

    hex = call(Api::Mcp::GetWorkflow, id: "0x1A")
    assert_predicate hex, :error?
    assert_equal "not_found", hex.structured_content[:errors].first[:code]
  end

  test "get_authoring_guide returns the schema version, schema and guide" do
    response = call(Api::Mcp::GetAuthoringGuide)
    data = response.structured_content
    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, data[:schema_version]
    assert_equal "object", data.dig(:schema, "type") || data.dig(:schema, :type)
    assert_predicate data[:guide], :present?
  end

  private

  def call(tool, **arguments)
    context = { user: @editor, api_token: @token,
                catalog: Api::WorkflowCatalog.new(@editor, base_url: "http://example.test") }
    delivered = JSON.parse(JSON.generate(arguments), symbolize_names: true)
    tool.call(**delivered, server_context: context)
  end
end
