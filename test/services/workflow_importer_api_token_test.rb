require "test_helper"

class WorkflowImporterApiTokenTest < ActiveSupport::TestCase
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "t", scopes: %w[read draft], expires_in_days: 7)
  end

  test "a strict import through a token records the token" do
    result = import(api_token: @token)
    assert_predicate result, :success?
    assert_equal @token, result.workflow.api_token
    assert_includes Workflow.created_via_api, result.workflow
  end

  test "an import without a token records none" do
    result = import
    assert_predicate result, :success?
    assert_nil result.workflow.api_token_id
  end

  test "deleting the token keeps the draft and clears the label" do
    workflow = import(api_token: @token).workflow
    @token.destroy!
    assert_nil workflow.reload.api_token_id
  end

  private

  def import(api_token: nil)
    content = { schema_version: "1", workflows: [{
      title: "Imported #{SecureRandom.hex(2)}",
      steps: [{ id: "done", type: "resolve", title: "Done", resolution_type: "success" }]
    }] }.to_json
    report = StrictImportValidator.new(user: @editor, content:).validate
    assert_predicate report, :valid?, report.errors.inspect
    WorkflowImporter.new(@editor, format: :json, content:, strict_report: report, api_token:).call
  end
end
