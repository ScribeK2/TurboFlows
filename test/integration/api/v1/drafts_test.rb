require "test_helper"

class Api::V1::DraftsTest < ActionDispatch::IntegrationTest
  include StrictDocumentNormalizer

  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @drafter = ApiToken.issue(user: @editor, name: "d", scopes: %w[read draft], expires_in_days: 7)
    @reader = ApiToken.issue(user: @editor, name: "r", scopes: %w[read], expires_in_days: 7)
  end

  test "a read-only token cannot create or validate" do
    post api_v1_drafts_path, params: document, headers: headers(@reader)
    assert_response :forbidden
    post api_v1_draft_validation_path, params: document, headers: headers(@reader)
    assert_response :forbidden
  end

  test "a demoted editor's draft token is refused" do
    @editor.update!(role: "user")
    post api_v1_drafts_path, params: document, headers: headers(@drafter)
    assert_response :forbidden
  end

  test "create answers 201 with ids and builder urls" do
    post api_v1_drafts_path, params: document, headers: headers(@drafter)
    assert_response :created
    created = response.parsed_body["workflows"].sole
    assert_equal "http://www.example.com/workflows/#{created['id']}", created["url"]
  end

  test "validate answers 200 whether or not the document is valid" do
    post api_v1_draft_validation_path, params: document, headers: headers(@drafter)
    assert_response :success
    assert response.parsed_body["valid"]

    post api_v1_draft_validation_path, params: "{nope", headers: headers(@drafter)
    assert_response :success
    assert_equal "malformed_json", response.parsed_body.dig("errors", 0, "code")
  end

  test "a malformed body on create is a 422 finding, not a 400 page" do
    post api_v1_drafts_path, params: "{nope", headers: headers(@drafter)
    assert_response :unprocessable_content
    assert_equal "malformed_json", response.parsed_body.dig("errors", 0, "code")
  end

  test "a body over 10 MB is a 413" do
    post api_v1_drafts_path, params: "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1), headers: headers(@drafter)
    assert_response :content_too_large
    assert_equal "payload_too_large", response.parsed_body.dig("errors", 0, "code")
  end

  test "a valid document over 10 MB is still a 413, not parsed and imported" do
    oversized = { schema_version: "1", workflows: [{
      title: "Oversized #{SecureRandom.hex(2)}",
      description: "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1),
      steps: [{ id: "done", type: "resolve", title: "Done", resolution_type: "success" }]
    }] }.to_json

    assert_no_difference("Workflow.count") do
      post api_v1_drafts_path, params: oversized, headers: headers(@drafter)
      assert_response :content_too_large
      assert_equal "payload_too_large", response.parsed_body.dig("errors", 0, "code")
    end
  end

  test "the production log never carries the document's content" do
    distinctive = "Logging Canary #{SecureRandom.hex(4)}"
    doc = { schema_version: "1", workflows: [{ title: distinctive,
                                               steps: [{ id: "done", type: "resolve", title: "Done",
                                                         resolution_type: "success" }] }] }.to_json

    logged_params = nil
    subscriber = ->(event) { logged_params = event.payload[:params] }

    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      post api_v1_drafts_path, params: doc, headers: headers(@drafter)
    end

    assert_response :created
    assert_not_nil logged_params
    assert_equal "[FILTERED]", logged_params["workflows"]
    assert_not_includes logged_params.inspect, distinctive
  end

  test "GET a workflow, POST it back as a draft: the same workflow" do
    post api_v1_drafts_path, params: round_trip_source, headers: headers(@drafter)
    assert_response :created
    source_id = response.parsed_body["workflows"].sole["id"]

    get api_v1_workflow_path(source_id), headers: headers(@drafter)
    original = response.parsed_body["document"]

    post api_v1_drafts_path, params: original.to_json, headers: headers(@drafter)
    assert_response :created
    get api_v1_workflow_path(response.parsed_body["workflows"].sole["id"]), headers: headers(@drafter)

    assert_equal normalize(original), normalize(response.parsed_body["document"])
  end

  private

  def headers(token)
    { "Authorization" => "Bearer #{token.plaintext}", "Content-Type" => "application/json" }
  end

  def document
    { schema_version: "1", workflows: [{ title: "API #{SecureRandom.hex(2)}",
                                         steps: [{ id: "done", type: "resolve", title: "Done",
                                                   resolution_type: "success" }] }] }.to_json
  end

  # A branching workflow, so the comparison checks topology and not just one step.
  def round_trip_source
    { schema_version: "1", workflows: [{
      title: "API round trip #{SecureRandom.hex(2)}",
      steps: [
        { id: "ask", type: "question", title: "Which issue?", question: "Which issue?",
          answer_type: "multiple_choice", variable_name: "issue",
          options: [{ label: "Billing", value: "billing" }, { label: "Other", value: "other" }],
          transitions: [{ target_id: "act", condition: "issue == 'billing'" }, { target_id: "done" }] },
        { id: "act", type: "action", title: "Check the account", instructions: "Check the account",
          transitions: [{ target_id: "done" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }] }.to_json
  end
end
