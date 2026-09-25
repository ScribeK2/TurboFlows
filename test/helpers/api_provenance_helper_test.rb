require "test_helper"

class ApiProvenanceHelperTest < ActionView::TestCase
  include ApiProvenanceHelper

  test "api_provenance_badge carries the api-provenance class, for the long-unbroken-run CSS treatment" do
    editor = User.create!(email: "prov-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    token = ApiToken.issue(user: editor, name: "Claude Code laptop", scopes: %w[draft], expires_in_days: 7)
    workflow = Workflow.create!(title: "Via API", user: editor, status: "draft", api_token: token)

    badge = api_provenance_badge(workflow)

    assert_includes badge, 'class="badge badge--info api-provenance"'
    assert_includes badge, "Created via API · Claude Code laptop"
  end

  test "api_provenance_badge is nil for a workflow not made through the API" do
    editor = User.create!(email: "prov-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    workflow = Workflow.create!(title: "By hand", user: editor, status: "draft")

    assert_nil api_provenance_badge(workflow)
  end
end
