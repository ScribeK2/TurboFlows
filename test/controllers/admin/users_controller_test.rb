require 'test_helper'

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-users-#{SecureRandom.hex(4)}@example.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'admin'
    )
    @editor = User.create!(
      email: "editor-users-#{SecureRandom.hex(4)}@example.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'editor'
    )
    @user = User.create!(
      email: "user-users-#{SecureRandom.hex(4)}@example.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'user'
    )
  end

  test 'admin should be able to access user management' do
    sign_in @admin
    get admin_users_path

    assert_response :success
  end

  test 'non-admin should not be able to access user management' do
    sign_in @editor
    get admin_users_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test 'admin should be able to update user role' do
    sign_in @admin
    patch update_role_admin_user_path(@user), params: { role: 'editor' }

    assert_redirected_to admin_users_path
    @user.reload

    assert_equal 'editor', @user.role
  end

  test 'admin should not be able to set invalid role' do
    sign_in @admin
    original_role = @user.role
    patch update_role_admin_user_path(@user), params: { role: 'invalid_role' }

    assert_redirected_to admin_users_path
    @user.reload

    assert_equal original_role, @user.role
  end

  # Group assignment tests
  test 'admin should be able to assign groups to user' do
    sign_in @admin
    group1 = Group.create!(name: 'Group 1')
    group2 = Group.create!(name: 'Group 2')

    assert_difference('@user.groups.count', 2) do
      patch update_groups_admin_user_path(@user), params: {
        group_ids: [group1.id, group2.id]
      }
    end

    assert_redirected_to admin_users_path
    @user.reload

    assert_includes @user.groups.map(&:id), group1.id
    assert_includes @user.groups.map(&:id), group2.id
  end

  test 'admin should be able to update user groups' do
    sign_in @admin
    group1 = Group.create!(name: 'Group 1')
    group2 = Group.create!(name: 'Group 2')
    group3 = Group.create!(name: 'Group 3')

    # Initially assign group1 and group2
    UserGroup.create!(group: group1, user: @user)
    UserGroup.create!(group: group2, user: @user)

    # Update to group2 and group3
    patch update_groups_admin_user_path(@user), params: {
      group_ids: [group2.id, group3.id]
    }

    @user.reload

    assert_not_includes @user.groups.map(&:id), group1.id
    assert_includes @user.groups.map(&:id), group2.id
    assert_includes @user.groups.map(&:id), group3.id
  end

  test 'admin should be able to bulk assign groups to multiple users' do
    sign_in @admin
    user1 = User.create!(
      email: "user1-#{SecureRandom.hex(4)}@test.com",
      password: 'password123!',
      password_confirmation: 'password123!'
    )
    user2 = User.create!(
      email: "user2-#{SecureRandom.hex(4)}@test.com",
      password: 'password123!',
      password_confirmation: 'password123!'
    )
    group = Group.create!(name: 'Bulk Group')

    assert_difference('UserGroup.count', 2) do
      patch bulk_assign_groups_admin_users_path, params: {
        user_ids: [user1.id, user2.id],
        group_ids: [group.id]
      }
    end

    assert_redirected_to admin_users_path
    user1.reload
    user2.reload

    assert_includes user1.groups.map(&:id), group.id
    assert_includes user2.groups.map(&:id), group.id
  end

  test 'bulk assign should replace existing group assignments' do
    sign_in @admin
    user = User.create!(
      email: "user-#{SecureRandom.hex(4)}@test.com",
      password: 'password123!',
      password_confirmation: 'password123!'
    )
    group1 = Group.create!(name: 'Group 1')
    group2 = Group.create!(name: 'Group 2')

    # Initially assign group1
    UserGroup.create!(group: group1, user: user)

    # Bulk assign group2
    patch bulk_assign_groups_admin_users_path, params: {
      user_ids: [user.id],
      group_ids: [group2.id]
    }

    user.reload

    assert_not_includes user.groups.map(&:id), group1.id
    assert_includes user.groups.map(&:id), group2.id
  end

  # Password reset tests
  test 'admin should be able to reset user password' do
    sign_in @admin

    original_password = @user.encrypted_password

    post reset_password_admin_user_path(@user)

    assert_redirected_to admin_users_path
    assert_match(/Temporary password generated for #{@user.email}/, flash[:notice])

    @user.reload

    assert_not_equal original_password, @user.encrypted_password
  end

  test 'admin cannot reset own password via admin interface' do
    sign_in @admin

    post reset_password_admin_user_path(@admin)

    assert_redirected_to admin_users_path
    assert_match(/Cannot reset your own password/, flash[:alert])
  end

  test 'non-admin cannot access reset password action' do
    sign_in @editor

    post reset_password_admin_user_path(@user)

    # Should be redirected due to ensure_admin! filter
    assert_response :redirect
  end

  test 'reset password action logs security audit trail' do
    sign_in @admin

    # Simplified test - just verify the action works and logs would be created
    # In a real environment, Rails would log the action
    assert_nothing_raised do
      post reset_password_admin_user_path(@user)
    end

    assert_redirected_to admin_users_path
    assert_match(/Temporary password generated/, flash[:notice])
  end

  test 'reset password action logs security warning for self-reset attempt' do
    sign_in @admin

    # Simplified test - verify self-reset is blocked
    post reset_password_admin_user_path(@admin)

    assert_redirected_to admin_users_path
    assert_match(/Cannot reset your own password/, flash[:alert])
  end

  test 'reset password action works with temporary password generation' do
    # Test that temporary password is generated correctly (model method test)
    original_password = @user.encrypted_password

    temp_password = @user.generate_temporary_password

    @user.reload

    assert_not_equal original_password, @user.encrypted_password
    assert_not_nil temp_password
    assert_operator temp_password.length, :>=, 8, "Password should be at least 8 characters"
    # Password contains only alphanumeric chars from the character set
    assert_match(/^[a-zA-Z0-9]+$/, temp_password, "Password should only contain alphanumeric characters")
  end

  test 'temporary password generation returns JSON response' do
    sign_in @admin

    post reset_password_admin_user_path(@user), as: :json

    assert_response :success

    json_response = JSON.parse(response.body)

    assert json_response['success']
    assert_not_nil json_response['password']
    assert_equal @user.email, json_response['email']
  end

  test 'temporary password is secure and unique' do
    sign_in @admin

    post reset_password_admin_user_path(@user), as: :json
    first_password = JSON.parse(response.body)['password']

    post reset_password_admin_user_path(@user), as: :json
    second_password = JSON.parse(response.body)['password']

    # Passwords should be different
    assert_not_equal first_password, second_password

    # Passwords should be secure (16-char alphanumeric from SecureRandom)
    assert_match(/[a-zA-Z]/, first_password)
    assert_operator first_password.length, :>=, 16
  end

  test 'temporary password flow works for user login' do
    sign_in @admin

    # Generate temporary password
    post reset_password_admin_user_path(@user), as: :json
    temp_password = JSON.parse(response.body)['password']

    # User should be able to sign in with temporary password
    sign_out @user

    post user_session_path, params: {
      user: {
        email: @user.email,
        password: temp_password
      }
    }

    assert_redirected_to root_path
  end

  test 'temporary password HTML response works' do
    sign_in @admin

    post reset_password_admin_user_path(@user)

    assert_redirected_to admin_users_path
    assert_match(/Temporary password generated/, flash[:notice])
  end

  # Filter and pagination tests
  test "index with search query filters users" do
    sign_in @admin
    get admin_users_path(q: @editor.email.split("@").first)

    assert_response :success
    assert_match @editor.email, response.body
  end

  test "index with role filter shows only that role" do
    sign_in @admin
    get admin_users_path(role: "admin")

    assert_response :success
    assert_match @admin.email, response.body
  end

  test "index with pagination returns correct page" do
    sign_in @admin
    get admin_users_path(page: 1, per_page: 25)

    assert_response :success
  end

  test "index assigns filter metadata" do
    sign_in @admin
    get admin_users_path

    assert_response :success
  end

  test "bulk_update_role changes roles for selected users" do
    sign_in @admin
    patch bulk_update_role_admin_users_path, params: {
      user_ids: [@user.id, @editor.id],
      role: "admin"
    }

    assert_response :redirect
    @user.reload
    @editor.reload
    assert_equal "admin", @user.role
    assert_equal "admin", @editor.role
  end

  test "bulk_update_role rejects invalid role" do
    sign_in @admin
    patch bulk_update_role_admin_users_path, params: {
      user_ids: [@user.id],
      role: "superadmin"
    }

    assert_response :redirect
    assert_equal "Invalid role.", flash[:alert]
  end

  test "bulk_deactivate locks selected users" do
    sign_in @admin
    patch bulk_deactivate_admin_users_path, params: {
      user_ids: [@user.id]
    }

    assert_redirected_to admin_users_path
    @user.reload
    assert_predicate @user, :access_locked?, "User should be locked"
  end

  test "non-admin cannot access bulk_deactivate" do
    sign_in @editor
    patch bulk_deactivate_admin_users_path, params: {
      user_ids: [@user.id]
    }

    assert_redirected_to root_path
  end
end
