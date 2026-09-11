require "test_helper"

class UserSelfJoinTest < ActiveSupport::TestCase
  setup do
    tag = SecureRandom.hex(3)
    @user = person("regular")
    @support = Group.create!(name: "Support #{tag}")
    @tier1 = Group.create!(name: "Tier 1", parent: @support)
    @escalations = Group.create!(name: "Escalations", parent: @support, admins_add_members: true)
    @hr = Group.create!(name: "HR #{tag}")
  end

  # -- awaiting_groups? --

  test "awaiting_groups? agrees with the awaiting_groups scope for every kind of account" do
    accounts = [
      person("regular"), person("editor"), person("admin"),
      person("regular", deactivated_at: 1.day.ago),
      person("regular").tap { UserGroup.create!(user: it, group: @hr) }
    ]
    scoped = User.awaiting_groups.pluck(:id)

    accounts.each do |account|
      assert_equal scoped.include?(account.id), account.awaiting_groups?, "#{account.role} #{account.email}"
    end
  end

  # -- join_groups! --

  test "join_groups! joins joinable groups and marks them self-joined" do
    joined = @user.join_groups!([@tier1.id.to_s, @hr.id.to_s, ""])

    assert_equal [@tier1.id, @hr.id].sort, joined.sort
    assert_predicate UserGroup.find_by!(user: @user, group: @tier1), :self_joined?
    assert_predicate UserGroup.find_by!(user: @user, group: @hr), :self_joined?
  end

  test "join_groups! refuses the whole request when any group is not joinable" do
    assert_raises(Group::NotSelfJoinable) { @user.join_groups!([@tier1.id, @escalations.id]) }
    assert_raises(Group::NotSelfJoinable) { @user.join_groups!([@support.id]) }
    assert_raises(Group::NotSelfJoinable) { @user.join_groups!([global_group.id]) }

    assert_empty @user.user_groups.reload
  end

  test "join_groups! leaves a group they are already in with the origin it has" do
    UserGroup.create!(user: @user, group: @tier1)

    joined = @user.join_groups!([@tier1.id, @hr.id])

    assert_equal [@hr.id], joined
    assert_not UserGroup.find_by!(user: @user, group: @tier1).self_joined?
  end

  test "joining a group makes its workflows visible, and for an editor, a group they can file into" do
    editor = person("editor")
    editor.join_groups!([@hr.id])

    assert_includes Group.reachable_ids_for(editor), @hr.id
    assert_equal [@hr.id], Group.assignable_ids_for(editor, [@hr.id], current_ids: [])
  end

  # -- leave_group! --

  test "leave_group! removes a joinable membership, whoever made it" do
    UserGroup.create!(user: @user, group: @tier1)

    @user.leave_group!(@tier1)

    assert_not UserGroup.exists?(user: @user, group: @tier1)
  end

  test "leave_group! refuses a group they could not rejoin" do
    UserGroup.create!(user: @user, group: @escalations)
    UserGroup.create!(user: @user, group: @support)

    assert_raises(Group::NotSelfJoinable) { @user.leave_group!(@escalations) }
    assert_raises(Group::NotSelfJoinable) { @user.leave_group!(@support) }
    assert_equal 2, @user.user_groups.reload.size
  end

  test "leaving the last group puts them back among those awaiting groups" do
    @user.join_groups!([@hr.id])
    assert_not @user.awaiting_groups?

    @user.leave_group!(@hr)

    assert_predicate @user, :awaiting_groups?
  end

  # -- replace_groups! --

  test "replace_groups! adds and removes, and a membership that stays keeps its origin" do
    @user.join_groups!([@tier1.id, @hr.id])

    @user.replace_groups!([@tier1.id.to_s, @escalations.id.to_s, ""])

    memberships = @user.user_groups.reload.index_by(&:group_id)
    assert_equal [@tier1.id, @escalations.id].sort, memberships.keys.sort
    assert_predicate memberships[@tier1.id], :self_joined?, "an admin save keeps a self-join's origin (Q15)"
    assert_not memberships[@escalations.id].self_joined?, "an admin add is admin-assigned"
  end

  test "replace_groups! with nothing removes every group" do
    @user.join_groups!([@hr.id])

    @user.replace_groups!(nil)

    assert_empty @user.user_groups.reload
  end

  test "locking a group removes nobody" do
    @user.join_groups!([@hr.id])

    @hr.update!(admins_add_members: true)

    assert UserGroup.exists?(user: @user, group: @hr, self_joined: true)
  end

  private

  def person(role, **attrs)
    User.create!(email: "self-join-#{role}-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role, **attrs)
  end
end
