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

  test "a document with no schema_version is a 422 unsupported_schema_version, not a 201" do
    no_version = { workflows: [{ title: "API #{SecureRandom.hex(2)}",
                                 steps: [{ id: "done", type: "resolve", title: "Done",
                                           resolution_type: "success" }] }] }.to_json
    post api_v1_drafts_path, params: no_version, headers: headers(@drafter)
    assert_response :unprocessable_content
    assert_equal "unsupported_schema_version", response.parsed_body.dig("errors", 0, "code")
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

  # The router squeezes a doubled slash down to one before matching a route
  # (confirmed below), so /api//v1/drafts still resolves to drafts#create —
  # the body guard has to recognize it as the same endpoint too, or the
  # document reaches the log unfiltered.
  test "a doubled slash still routes to drafts#create" do
    assert_equal({ format: :json, controller: "api/v1/drafts", action: "create" },
                 Rails.application.routes.recognize_path("/api//v1/drafts", method: :post))
  end

  test "the production log never carries the document's content, over /api//v1/drafts either" do
    distinctive = "Logging Canary #{SecureRandom.hex(4)}"
    doc = { schema_version: "1", workflows: [{ title: distinctive,
                                               steps: [{ id: "done", type: "resolve", title: "Done",
                                                         resolution_type: "success" }] }] }.to_json

    logged_params = nil
    subscriber = ->(event) { logged_params = event.payload[:params] }

    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      post "/api//v1/drafts", params: doc, headers: headers(@drafter)
    end

    assert_response :created
    assert_not_nil logged_params
    assert_equal "[FILTERED]", logged_params["workflows"]
    assert_not_includes logged_params.inspect, distinctive
  end

  # namespace :api gets format: false (config/routes.rb): no /api/**.<format>
  # URL reaches DraftsController, so a body guarded by exact path never has a
  # format-suffixed twin to miss. Before this, /api/v1/drafts.json and
  # /api/v1/drafts/validate.json both routed and skipped
  # Api::DraftBodyGuard's exact/prefix path match. Since the catch-all
  # (config/routes.rb) was added, the suffixed URL now routes too — but only
  # to the API's own JSON 404 (Api::V1::NotFoundController, a bare
  # ActionController::Metal that never touches params), never to
  # DraftsController, so the guard still has nothing to miss.
  test "a .json-suffixed drafts URL routes only to the JSON 404, never to drafts#create" do
    route = Rails.application.routes.recognize_path("/api/v1/drafts.json", method: :post)
    assert_equal "api/v1/not_found", route[:controller]
  end

  test "a .json-suffixed drafts/validate URL routes only to the JSON 404, never to drafts/validations#create" do
    route = Rails.application.routes.recognize_path("/api/v1/drafts/validate.json", method: :post)
    assert_equal "api/v1/not_found", route[:controller]
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
