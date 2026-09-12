require "test_helper"

class GroupManagerTest < ActiveSupport::TestCase
  setup do
    @tag = SecureRandom.hex(3)
    @user = User.create!(email: "gm-#{@tag}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "user")
    @team = Group.create!(name: "GM Team #{@tag}")
  end

  test "a regular user can manage a group without being a member of it" do
    GroupManager.create!(group: @team, user: @user)

    assert_equal [@team], @user.managed_groups.to_a
    assert_equal [@user], @team.managers.to_a
    assert_empty @user.groups
  end

  test "each person manages a group once" do
    GroupManager.create!(group: @team, user: @user)
    duplicate = GroupManager.new(group: @team, user: @user)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "Global has no managers" do
    grant = GroupManager.new(group: global_group, user: @user)

    assert_not grant.valid?
    assert_match(/Global has no managers/, grant.errors.full_messages.to_sentence)
  end

  test "managers_by_email lists the grants ordered by email" do
    zed = User.create!(email: "zed-#{@tag}@example.com", password: "password123!",
                       password_confirmation: "password123!", role: "user")
    GroupManager.create!(group: @team, user: zed)
    GroupManager.create!(group: @team, user: @user)

    expected = [@user.email, zed.email]
    actual = @team.managers_by_email.map { |gm| gm.user.email }
    assert_equal expected, actual
  end

  test "deleting the group or the user deletes the grant" do
    other = Group.create!(name: "GM Other #{@tag}")
    GroupManager.create!(group: @team, user: @user)
    GroupManager.create!(group: other, user: @user)

    assert_difference -> { GroupManager.count }, -1 do
      @team.destroy!
    end
    assert_difference -> { GroupManager.count }, -1 do
      @user.destroy!
    end
  end
end
