require "test_helper"

# A self-join is marked where an admin looks at who is in what (spec 2026-09-11
# Q9), and an admin save of someone's groups keeps the mark (Q15).
class Admin::SelfJoinedMarksTest < ActionDispatch::IntegrationTest
  setup do
    tag = SecureRandom.hex(4)
    @admin = User.create!(email: "marks-admin-#{tag}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    @ada = User.create!(email: "marks-ada-#{tag}@example.com", password: "password123!",
                        password_confirmation: "password123!", role: "regular")
    @support = Group.create!(name: "Marks Support #{tag}")
    @billing = Group.create!(name: "Marks Billing #{tag}")
    @ada.join_groups!([@support.id])
    sign_in @admin
  end

  test "Save Groups on the user page keeps a self-join's mark" do
    patch update_groups_admin_user_path(@ada), params: { group_ids: [@support.id, @billing.id] }

    assert_redirected_to admin_user_path(@ada)
    assert_predicate UserGroup.find_by!(user: @ada, group: @support), :self_joined?
    assert_not UserGroup.find_by!(user: @ada, group: @billing).self_joined?
  end

  test "bulk assign still replaces each person's groups, and keeps the mark on one that stays" do
    patch bulk_assign_groups_admin_users_path, params: { user_ids: [@ada.id], group_ids: [@support.id] }

    assert_equal [@support.id], @ada.user_groups.reload.map(&:group_id)
    assert_predicate UserGroup.find_by!(user: @ada, group: @support), :self_joined?

    patch bulk_assign_groups_admin_users_path, params: { user_ids: [@ada.id], group_ids: [@billing.id] }

    assert_equal [@billing.id], @ada.user_groups.reload.map(&:group_id)
  end

  test "adding someone from the group page is admin-assigned" do
    person = User.create!(email: "marks-bob-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "regular")

    post admin_group_memberships_path(@billing), params: { user_id: person.id }

    assert_not UserGroup.find_by!(user: person, group: @billing).self_joined?
  end

  test "the group page's member list says who joined themselves" do
    UserGroup.create!(user: @admin, group: @support)

    get admin_group_path(@support)

    assert_select "#group-members .admin-group__item", 2
    assert_select "#group-members .admin-group__item", text: /#{Regexp.escape(@ada.email)}.*Joined themselves/m
    assert_select "#group-members .admin-group__item", text: /#{Regexp.escape(@admin.email)}/ do |items|
      assert_no_match(/Joined themselves/, items.first.text)
    end
  end

  test "the user page marks the groups they joined themselves" do
    UserGroup.create!(user: @ada, group: @billing)

    get admin_user_path(@ada)

    assert_select ".group-picker__option[data-path=?] .group-picker__note", @support.name.downcase, text: "Joined themselves"
    assert_select ".group-picker__option[data-path=?] .group-picker__note", @billing.name.downcase, count: 0
  end
end
