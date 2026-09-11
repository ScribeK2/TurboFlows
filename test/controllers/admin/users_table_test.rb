require "test_helper"

# The slim users table (Stage 3): a row is who, role, groups and joined, and
# everything else about a person lives on their page. Sorting, filtering, paging
# and the bulk actions are covered in users_controller_test.rb.
class Admin::UsersTableTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "table-admin-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    @user = User.create!(email: "table-user-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "regular")
    sign_in @admin
  end

  test "each row links its email to the user page, outside the table's frame" do
    get admin_users_path(q: @user.email)

    assert_select "tbody a.admin-users__email[href=?][data-turbo-frame=_top]", admin_user_path(@user),
                  text: @user.email
  end

  test "the table renders no per-row buttons or dialogs" do
    get admin_users_path

    assert_select "[id^=group-modal-]", 0
    assert_select "tbody button", 0
    assert_select "tbody form[action$=deactivate]", 0
    assert_select "[data-admin-users-target=resetModal]", 0
  end

  test "a row shows two group names, then a count whose title lists every path" do
    parent = Group.create!(name: "Row Parent #{SecureRandom.hex(3)}")
    groups = %w[Alpha Beta Gamma].map { Group.create!(name: it, parent: parent) }
    groups.each { UserGroup.create!(user: @user, group: it) }

    get admin_users_path(q: @user.email)

    row = css_select("tbody tr:has(a[href='#{admin_user_path(@user)}'])").first
    assert row, "no row for #{@user.email}"
    shown = row.css(".admin-users__group").map { it.text.strip }
    assert_equal %w[Alpha Beta], shown
    more = row.css(".admin-users__more").first
    assert_equal "+1", more.text.strip
    groups.each { assert_includes more["title"], "#{parent.name} / #{it.name}" }
  end

  # A byte-order sort put every capitalised path first: "WSO / ATSR" before
  # "Web Support", and "Zeta" before "alpha".
  test "a row orders its groups by path ignoring case" do
    parent = Group.create!(name: "Case Parent #{SecureRandom.hex(3)}")
    %w[beta Alpha Charlie].each { UserGroup.create!(user: @user, group: Group.create!(name: it, parent: parent)) }

    get admin_users_path(q: @user.email)

    row = css_select("tbody tr:has(a[href='#{admin_user_path(@user)}'])").first
    shown = row.css(".admin-users__group").map { it.text.strip }
    assert_equal %w[Alpha beta], shown
  end

  test "the bulk dialogs are native dialogs, and assigning groups uses the path-aware picker" do
    parent = Group.create!(name: "Bulk Parent #{SecureRandom.hex(3)}")
    child = Group.create!(name: "Bulk Child", parent: parent)

    get admin_users_path

    assert_select ".dialog-overlay", 0
    assert_select "dialog.dialog[data-admin-users-target=roleModal] form[action=?]", bulk_update_role_admin_users_path
    assert_select "dialog.dialog[data-admin-users-target=bulkModal] form[action=?] [data-controller=group-picker]",
                  bulk_assign_groups_admin_users_path
    assert_select "dialog[data-admin-users-target=bulkModal] input[name='group_ids[]'][value=?]", child.id.to_s
    assert_select "dialog[data-admin-users-target=bulkModal] .group-picker__path", text: "#{parent.name} / Bulk Child"
  end

  test "no membership picker offers Global, which has no members" do
    global = global_group

    get admin_users_path
    assert_select "input[name='group_ids[]'][value=?]", global.id.to_s, 0

    get admin_user_path(@user)
    assert_select "input[name='group_ids[]'][value=?]", global.id.to_s, 0
  end

  # Full paths in every group picker (spec, Q31 carried into Stage 4): a bare
  # "Support" can't be told from another department's "Support". The filter
  # stays exact (Q37): it lists who is in the group, not its parent's members.
  test "the group filter names groups by path, and lists only the group's own members" do
    parent = Group.create!(name: "Filter Parent #{SecureRandom.hex(3)}")
    child = Group.create!(name: "Filter Child", parent:)
    UserGroup.create!(user: @user, group: parent)

    get admin_users_path(group: child.id)

    assert_select "select[name=group] option[value=?]", child.id.to_s, text: "#{parent.name} / Filter Child"
    assert_select ".admin-filter-pill", text: %r{Group: #{Regexp.escape(parent.name)} / Filter Child}
    assert_select "tbody a[href=?]", admin_user_path(@user), 0
  end

  # The filter toolbar and the Change Role dialog each rendered a role select
  # through form_with, and both came out as id="role". The dialog's label then
  # named the filter "New role for the selected users" and left its own select
  # unlabelled. Found by /qa on 2026-09-11 (ISSUE-003).
  test "the page has no duplicate ids, with every filter in the URL" do
    group = Group.create!(name: "Ids #{SecureRandom.hex(3)}")
    UserGroup.create!(user: @user, group: group)

    get admin_users_path(q: "table-user", role: "regular", group: group.id, sort: "email_asc", per_page: 25)

    ids = css_select("[id]").pluck("id")
    assert_empty ids.tally.select { |_, count| count > 1 }.keys
  end

  test "the Change Role label names the dialog's own select, and each filter has its own name" do
    get admin_users_path

    label = css_select("dialog[data-admin-users-target=roleModal] label").first
    assert_select "dialog[data-admin-users-target=roleModal] select[id=?]", label["for"]
    assert_select ".admin-filter-toolbar select[name=role][aria-label=?]", "Filter by role"
    assert_select ".admin-filter-toolbar select[name=group][aria-label=?]", "Filter by group"
  end
end
