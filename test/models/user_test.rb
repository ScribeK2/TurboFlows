require "test_helper"

class UserTest < ActiveSupport::TestCase
  # Load fixtures only for model tests that need them
  fixtures :users

  test "should create valid user" do
    user = User.new(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )

    assert_predicate user, :valid?
  end

  test "should not create user without email" do
    user = User.new(password: "password123!")

    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "should not create user without password" do
    user = User.new(email: "test@example.com")

    assert_not user.valid?
  end

  test "should have many workflows" do
    user = users(:one)

    assert_respond_to user, :workflows
  end

  test "should destroy workflows when user is destroyed" do
    user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    Workflow.create!(title: "Test", user: user)

    assert_difference("Workflow.count", -1) do
      user.destroy
    end
  end

  # Role Tests
  test "should default to user role" do
    user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )

    assert_equal "regular", user.role
  end

  test "should reject invalid role values" do
    assert_raises(ArgumentError) do
      User.new(
        email: "test@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "invalid_role"
      )
    end
  end

  test "admin? should return true for admin users" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )

    assert_predicate admin, :admin?
  end

  test "admin? should return false for non-admin users" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )

    assert_not user.admin?
  end

  test "editor? should return true for editor users" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    assert_predicate editor, :editor?
  end

  test "regular? should return true for regular users" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "regular"
    )

    assert_predicate user, :regular?
  end

  test "can_create_workflows? should return true for admin" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )

    assert_predicate admin, :can_create_workflows?
  end

  test "can_create_workflows? should return true for editor" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    assert_predicate editor, :can_create_workflows?
  end

  test "can_create_workflows? should return false for user" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )

    assert_not user.can_create_workflows?
  end

  test "can_manage_templates? should return true only for admin" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )

    assert_predicate admin, :can_manage_templates?
    assert_not editor.can_manage_templates?
    assert_not user.can_manage_templates?
  end

  test "can_access_admin? should return true only for admin" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    assert_predicate admin, :can_access_admin?
    assert_not editor.can_access_admin?
  end

  test "admins scope should return only admin users" do
    admin1 = User.create!(
      email: "admin1@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    admin2 = User.create!(
      email: "admin2@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    admins = User.admin

    assert_includes admins.map(&:id), admin1.id
    assert_includes admins.map(&:id), admin2.id
    assert_not_includes admins.map(&:id), editor.id
  end

  test "editors scope should return only editor users" do
    editor1 = User.create!(
      email: "editor1@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    editor2 = User.create!(
      email: "editor2@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )

    editors = User.editor

    assert_includes editors.map(&:id), editor1.id
    assert_includes editors.map(&:id), editor2.id
    assert_not_includes editors.map(&:id), user.id
  end

  # Group association tests
  test "should have many groups through user_groups" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")

    UserGroup.create!(group: group1, user: user)
    UserGroup.create!(group: group2, user: user)

    assert_equal 2, user.groups.count
    assert_includes user.groups.map(&:id), group1.id
    assert_includes user.groups.map(&:id), group2.id
  end

  test "accessible_groups should return all groups for admin" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")

    accessible = admin.accessible_groups

    assert_includes accessible.map(&:id), group1.id
    assert_includes accessible.map(&:id), group2.id
  end

  test "accessible_groups should return only assigned groups for non-admin" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    assigned_group = Group.create!(name: "Assigned Group")
    other_group = Group.create!(name: "Other Group")

    UserGroup.create!(group: assigned_group, user: user)

    accessible = user.accessible_groups

    assert_includes accessible.map(&:id), assigned_group.id
    assert_not_includes accessible.map(&:id), other_group.id
  end

  test "should destroy user_groups when user is destroyed" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group = Group.create!(name: "Test Group")
    UserGroup.create!(group: group, user: user)

    assert_difference("UserGroup.count", -1) do
      user.destroy
    end
  end

  test "should destroy user_groups when group is destroyed" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group = Group.create!(name: "Test Group")
    UserGroup.create!(group: group, user: user)

    assert_difference("UserGroup.count", -1) do
      group.destroy
    end
  end

  # Avatar helper tests
  test "avatar_initial returns first character of display_name uppercased" do
    user = User.new(display_name: "john", email: "john@example.com")
    assert_equal "J", user.avatar_initial
  end

  test "avatar_initial falls back to email first character when no display_name" do
    user = User.new(display_name: nil, email: "alice@example.com")
    assert_equal "A", user.avatar_initial
  end

  test "avatar_initial handles blank display_name" do
    user = User.new(display_name: "", email: "bob@example.com")
    assert_equal "B", user.avatar_initial
  end

  test "display_name is stripped on assignment" do
    user = User.new(display_name: "  John Doe  ")
    assert_equal "John Doe", user.display_name
  end

  test "avatar_color_class returns semantic class for user role" do
    user = User.new(role: "user")
    assert_equal "avatar--regular", user.avatar_color_class
  end

  test "avatar_color_class returns semantic class for editor role" do
    user = User.new(role: "editor")
    assert_equal "avatar--editor", user.avatar_color_class
  end

  test "avatar_color_class returns semantic class for admin role" do
    user = User.new(role: "admin")
    assert_equal "avatar--admin", user.avatar_color_class
  end

  test "avatar_role_badge_classes returns semantic class for user role" do
    user = User.new(role: "user")
    assert_equal "badge--regular", user.avatar_role_badge_classes
  end

  test "avatar_role_badge_classes returns semantic class for editor role" do
    user = User.new(role: "editor")
    assert_equal "badge--editor", user.avatar_role_badge_classes
  end

  test "avatar_role_badge_classes returns semantic class for admin role" do
    user = User.new(role: "admin")
    assert_equal "badge--admin", user.avatar_role_badge_classes
  end

  test "user model responds to lockable attributes" do
    user = User.new
    assert_respond_to user, :failed_attempts
    assert_respond_to user, :locked_at
    assert_respond_to user, :unlock_token
    assert_respond_to user, :access_locked?
  end

  test "user model responds to timeoutable" do
    user = User.new
    assert_respond_to user, :timedout?
  end

  test "generate_temporary_password returns a 16-char alphanumeric string and updates password" do
    user = User.create!(
      email: "temppass@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )

    temp = user.generate_temporary_password

    assert_equal 16, temp.length
    assert_match(/\A[a-zA-Z0-9]+\z/, temp)
    assert user.valid_password?(temp), "User should be able to authenticate with the temporary password"
  end

  # Search scope tests
  test "search_by matches email" do
    user = User.create!(email: "findme@example.com", password: "password123!", password_confirmation: "password123!")
    results = User.search_by("findme")
    assert_includes results.map(&:id), user.id
  end

  test "search_by matches display_name" do
    user = User.create!(email: "x@example.com", password: "password123!", password_confirmation: "password123!", display_name: "John Smith")
    results = User.search_by("john")
    assert_includes results.map(&:id), user.id
  end

  test "search_by is case-insensitive" do
    user = User.create!(email: "CaseMix@Example.com", password: "password123!", password_confirmation: "password123!")
    results = User.search_by("casemix")
    assert_includes results.map(&:id), user.id
  end

  test "search_by returns empty when no match" do
    User.create!(email: "nope@example.com", password: "password123!", password_confirmation: "password123!")
    results = User.search_by("zzzznotfound")
    assert_empty results
  end

  test "by_role filters by role" do
    admin = User.create!(email: "a-role@test.com", password: "password123!", password_confirmation: "password123!", role: "admin")
    editor = User.create!(email: "e-role@test.com", password: "password123!", password_confirmation: "password123!", role: "editor")

    results = User.by_role("admin")
    assert_includes results.map(&:id), admin.id
    assert_not_includes results.map(&:id), editor.id
  end

  test "by_group returns users in the specified group" do
    user1 = User.create!(email: "g1@test.com", password: "password123!", password_confirmation: "password123!")
    user2 = User.create!(email: "g2@test.com", password: "password123!", password_confirmation: "password123!")
    group = Group.create!(name: "Filter Group")
    UserGroup.create!(user: user1, group: group)

    results = User.by_group(group.id)
    assert_includes results.map(&:id), user1.id
    assert_not_includes results.map(&:id), user2.id
  end

  test "by_group does not return duplicate users" do
    user = User.create!(email: "dup@test.com", password: "password123!", password_confirmation: "password123!")
    group1 = Group.create!(name: "G1")
    group2 = Group.create!(name: "G2")
    UserGroup.create!(user: user, group: group1)
    UserGroup.create!(user: user, group: group2)

    results = User.by_group(group1.id)
    assert_equal 1, results.where(id: user.id).count
  end

  test "sorted_by email_asc sorts by email ascending" do
    User.where(email: ["aaa@test.com", "zzz@test.com"]).destroy_all
    u1 = User.create!(email: "zzz@test.com", password: "password123!", password_confirmation: "password123!")
    u2 = User.create!(email: "aaa@test.com", password: "password123!", password_confirmation: "password123!")

    results = User.sorted_by("email_asc")
    ids = results.map(&:id)
    assert ids.index(u2.id) < ids.index(u1.id), "aaa@ should come before zzz@"
  end

  test "sorted_by defaults to created_at desc" do
    u1 = User.create!(email: "old-sort@test.com", password: "password123!", password_confirmation: "password123!")
    u2 = User.create!(email: "new-sort@test.com", password: "password123!", password_confirmation: "password123!")

    results = User.sorted_by(nil)
    ids = results.map(&:id)
    assert ids.index(u2.id) < ids.index(u1.id), "newer user should come first"
  end
end
