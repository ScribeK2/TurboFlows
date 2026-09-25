require "test_helper"

class Api::V1::WorkflowsTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @other = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "t", scopes: %w[read], expires_in_days: 7)
    @mine = Workflow.create!(title: "Mine #{SecureRandom.hex(2)}", user: @editor, status: "draft")
    @theirs = Workflow.create!(title: "Theirs #{SecureRandom.hex(2)}", user: @other, status: "draft")
  end

  test "index lists visible workflows with next_page" do
    get api_v1_workflows_path, headers: auth
    assert_response :success
    ids = response.parsed_body["workflows"].pluck("id")
    assert_includes ids, @mine.id
    assert_not_includes ids, @theirs.id
    assert response.parsed_body.key?("next_page")
  end

  test "show answers the strict document for a visible workflow" do
    get api_v1_workflow_path(@mine), headers: auth
    assert_response :success
    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, response.parsed_body.dig("document", "schema_version")
    assert_equal "http://www.example.com/workflows/#{@mine.id}", response.parsed_body["url"]
  end

  test "someone else's draft is a 404, not a 403" do
    get api_v1_workflow_path(@theirs), headers: auth
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("errors", 0, "code")
  end

  test "an enormous page number answers 200 with an empty page, not a 500" do
    get api_v1_workflows_path(page: "99999999999999999999"), headers: auth
    assert_response :success
    assert_equal [], response.parsed_body["workflows"]
  end

  # namespace :api gets format: false (config/routes.rb): no /api/**.<format>
  # URL should route at all, mirroring /mcp. Before this, /api/v1/workflows.json
  # routed the same as the suffix-less URL, an inconsistency the body guard
  # (which only ever matches drafts paths) doesn't need to close, but the
  # route itself should not offer.
  test "a .json-suffixed workflows URL does not route" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/api/v1/workflows.json", method: :get)
    end
  end

  test "an unknown filter is a 422 invalid_filter" do
    get api_v1_workflows_path(status: "archived"), headers: auth
    assert_response :unprocessable_content
    assert_equal "invalid_filter", response.parsed_body.dig("errors", 0, "code")
  end

  private

  def auth = { "Authorization" => "Bearer #{@token.plaintext}" }
end
