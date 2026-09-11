require "test_helper"

# The list toolbar's search form and the pagination's per-page form both carry
# the active filters as hidden fields, and hidden_field_tag gave each an id
# named after the param. With filters in the URL the page had two elements
# with id "status", "per_page" and so on, and the "Per page" label could point
# at a hidden field instead of its select. Found alongside /qa ISSUE-003,
# 2026-09-11.
class WorkflowsListIdsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "list-ids-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    group = Group.create!(name: "List Ids #{SecureRandom.hex(3)}")
    @workflow = Workflow.create!(title: "List Ids Workflow", user: @admin, status: "published")
    GroupWorkflow.create!(group: group, workflow: @workflow, is_primary: true)
    @group = group
    sign_in @admin
  end

  test "the list has no duplicate ids with every filter in the URL" do
    get workflows_path(status: "published", search: "List", group_id: @group.id, per_page: 25, sort: "title_asc")

    assert_response :success
    ids = css_select("[id]").pluck("id")
    assert_empty ids.tally.select { |_, count| count > 1 }.keys
  end

  test "the Per page label names its select" do
    get workflows_path(per_page: 25, status: "published")

    label = css_select("label.pagination-bar__per-page-label").first
    assert label, "no Per page label"
    assert_select "select.pagination-bar__per-page-select[id=?]", label["for"]
    assert_select "input[type=hidden][id=?]", label["for"], count: 0
  end
end
