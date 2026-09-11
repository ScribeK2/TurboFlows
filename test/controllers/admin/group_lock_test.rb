require "test_helper"

# "Only administrators add people" (spec 2026-09-11 Q11): a property of the group,
# set on its form, shown as plain text where the group is listed.
class Admin::GroupLockTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "lock-admin-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    sign_in @admin
    @group = Group.create!(name: "Lock Team #{SecureRandom.hex(4)}")
  end

  test "the form offers the lock, unticked, and tells whoever writes a description who reads it" do
    get edit_admin_group_path(@group)

    assert_select "input[type=checkbox][name='group[admins_add_members]']:not([checked])"
    assert_select "label", text: /Only administrators add people/
    assert_select ".form-hint", text: "Shown to people choosing a group."
  end

  test "saving the form sets and clears the lock" do
    patch admin_group_path(@group), params: { group: { name: @group.name, admins_add_members: "1" } }

    assert_redirected_to admin_group_path(@group)
    assert_predicate @group.reload, :admins_add_members?

    patch admin_group_path(@group), params: { group: { name: @group.name, admins_add_members: "0" } }

    assert_not_predicate @group.reload, :admins_add_members?
  end

  test "a new group starts open" do
    post admin_groups_path, params: { group: { name: "Lock New #{SecureRandom.hex(4)}" } }

    assert_not_predicate Group.order(:id).last, :admins_add_members?
  end

  test "the group page and its tree row say when only admins add people" do
    get admin_group_path(@group)
    assert_select ".page-header-section__ident", text: /Admins add people/, count: 0

    @group.update!(admins_add_members: true)

    get admin_group_path(@group)
    assert_select ".page-header-section__ident", text: /Admins add people/

    get admin_groups_path
    assert_select ".group-tree__row[data-id=?] .group-tree__managed", @group.id.to_s, text: "Admins add people"
    assert_select ".group-tree__managed.badge", 0
  end
end
