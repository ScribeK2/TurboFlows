require "test_helper"

class WorkflowsCreatedViaApiTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "Claude Code laptop", scopes: %w[read draft], expires_in_days: 7)
    @via_api = Workflow.create!(title: "Via API #{SecureRandom.hex(2)}", user: @editor, status: "draft",
                                api_token: @token)
    @by_hand = Workflow.create!(title: "By hand #{SecureRandom.hex(2)}", user: @editor, status: "draft")
    sign_in @editor
  end

  test "the list and the builder label an API draft with its token's name" do
    get workflows_path(status: "draft")
    assert_select ".badge", text: /Created via API · Claude Code laptop/, count: 1

    get workflow_path(@via_api)
    assert_select ".badge", text: /Created via API · Claude Code laptop/

    get workflow_path(@by_hand)
    assert_select ".badge", text: /Created via API/, count: 0
  end

  test "a revoked or expired token still labels its drafts" do
    @token.revoke!
    get workflow_path(@via_api)
    assert_select ".badge", text: /Created via API · Claude Code laptop/
  end

  test "a deleted token drops the name but keeps the draft" do
    @token.destroy!
    get workflow_path(@via_api)
    assert_response :success
    assert_select ".badge", text: /Created via API/, count: 0

    get workflows_path(status: "draft")
    assert_select ".badge", text: /Created via API/, count: 0
    assert_includes response.body, @via_api.title
  end

  test "the filter shows only API drafts and survives the status tabs and sort" do
    get workflows_path(source: "api")
    assert_includes response.body, @via_api.title
    assert_not_includes response.body, @by_hand.title

    assert_select "a.wf-status-tabs__tab[href*='source=api']", minimum: 2
    assert_select "option[value*='source=api']", minimum: 1
  end

  test "an unknown source value is ignored, not an error" do
    get workflows_path(source: "robots")
    assert_response :success
    assert_includes response.body, @by_hand.title
  end

  test "the next-page link keeps the filter across pagination" do
    (WorkflowsFilter::DEFAULT_PER_PAGE + 1).times do |n|
      Workflow.create!(title: "Bulk API draft #{n} #{SecureRandom.hex(2)}", user: @editor, status: "draft",
                       api_token: @token)
    end

    get workflows_path(source: "api", status: "draft")
    assert_select "a.pagination__item[href*='source=api']", minimum: 1
  end
end
