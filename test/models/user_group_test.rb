require "test_helper"

class UserGroupTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "ug-test@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    @group = Group.create!(name: "UG Group")
  end

  # Validations
  test "valid with user and group" do
    ug = UserGroup.new(user: @user, group: @group)
    assert ug.valid?
  end

  test "enforces uniqueness of user_id scoped to group_id" do
    UserGroup.create!(user: @user, group: @group)
    duplicate = UserGroup.new(user: @user, group: @group)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "allows same user with different groups" do
    group2 = Group.create!(name: "UG Group 2")
    UserGroup.create!(user: @user, group: @group)
    ug2 = UserGroup.new(user: @user, group: group2)
    assert ug2.valid?
  end

  test "allows same group with different users" do
    user2 = User.create!(
      email: "ug-test2@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    UserGroup.create!(user: @user, group: @group)
    ug2 = UserGroup.new(user: user2, group: @group)
    assert ug2.valid?
  end

  test "requires user_id" do
    ug = UserGroup.new(group: @group)
    assert_not ug.valid?
  end

  test "requires group_id" do
    ug = UserGroup.new(user: @user)
    assert_not ug.valid?
  end

  # Associations
  test "belongs to user" do
    ug = UserGroup.create!(user: @user, group: @group)
    assert_equal @user, ug.user
  end

  test "belongs to group" do
    ug = UserGroup.create!(user: @user, group: @group)
    assert_equal @group, ug.group
  end

  # Dependent destroy
  test "destroying user destroys user_groups" do
    UserGroup.create!(user: @user, group: @group)
    assert_difference("UserGroup.count", -1) do
      @user.destroy
    end
  end

  test "destroying group destroys user_groups" do
    UserGroup.create!(user: @user, group: @group)
    assert_difference("UserGroup.count", -1) do
      @group.destroy
    end
  end

  # User-Group through associations
  test "user association returns groups through user_groups" do
    group2 = Group.create!(name: "UG Group 2")
    UserGroup.create!(user: @user, group: @group)
    UserGroup.create!(user: @user, group: group2)

    groups = @user.groups
    assert_equal 2, groups.count
    assert_includes groups, @group
    assert_includes groups, group2
  end

  test "group association returns users through user_groups" do
    user2 = User.create!(
      email: "ug-test2@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    UserGroup.create!(user: @user, group: @group)
    UserGroup.create!(user: user2, group: @group)

    users = @group.users
    assert_equal 2, users.count
    assert_includes users, @user
    assert_includes users, user2
  end

  # Edge cases
  test "can have multiple user_groups for same user with different groups" do
    group2 = Group.create!(name: "UG Group 2")
    group3 = Group.create!(name: "UG Group 3")

    ug1 = UserGroup.create!(user: @user, group: @group)
    ug2 = UserGroup.create!(user: @user, group: group2)
    ug3 = UserGroup.create!(user: @user, group: group3)

    assert_equal 3, UserGroup.where(user: @user).count
  end

  test "can have multiple user_groups for same group with different users" do
    user2 = User.create!(
      email: "ug-test2@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    user3 = User.create!(
      email: "ug-test3@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )

    ug1 = UserGroup.create!(user: @user, group: @group)
    ug2 = UserGroup.create!(user: user2, group: @group)
    ug3 = UserGroup.create!(user: user3, group: @group)

    assert_equal 3, UserGroup.where(group: @group).count
  end

  test "group visibility for assigned user returns the assigned group" do
    UserGroup.create!(user: @user, group: @group)
    visible_groups = Group.visible_to(@user)

    assert_includes visible_groups, @group
  end

  test "group visibility for unassigned user does not return unassigned group" do
    user2 = User.create!(
      email: "ug-test2@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    visible_groups = Group.visible_to(user2)

    assert_not_includes visible_groups, @group
  end

  test "cascade deletion removes user_groups when group is destroyed" do
    user2 = User.create!(
      email: "ug-test2@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    UserGroup.create!(user: @user, group: @group)
    UserGroup.create!(user: user2, group: @group)

    assert_equal 2, UserGroup.where(group: @group).count
    @group.destroy

    assert_equal 0, UserGroup.where(group: @group).count
  end
end
