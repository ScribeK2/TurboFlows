require 'test_helper'

class AdminPasswordResetIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-reset-#{SecureRandom.hex(4)}@example.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'admin'
    )
    @user = User.create!(
      email: "user-reset-#{SecureRandom.hex(4)}@example.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'user'
    )
    @editor = User.create!(
      email: "editor-reset-#{SecureRandom.hex(4)}@example.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'editor'
    )
    ActionMailer::Base.deliveries.clear
  end

  test 'admin can see users list page' do
    sign_in @admin

    get admin_users_path

    assert_response :success

    # Should see users listed
    assert_select 'table'
  end

  test 'admin can generate temporary password for user' do
    sign_in @admin

    original_password = @user.encrypted_password

    post reset_password_admin_user_path(@user)

    assert_redirected_to admin_users_path
    assert_match(/Temporary password generated for #{@user.email}/, flash[:notice])

    # Password should be changed
    @user.reload

    assert_not_equal original_password, @user.encrypted_password
  end

  test 'admin can generate temporary password via JSON request' do
    sign_in @admin

    @user.encrypted_password

    post reset_password_admin_user_path(@user), as: :json

    assert_response :success

    json_response = JSON.parse(response.body)

    assert json_response['success']
    assert_not_nil json_response['password']
    assert_equal @user.email, json_response['email']

    # Verify password works
    @user.reload

    assert @user.valid_password?(json_response['password'])
  end

  test 'admin cannot reset own password' do
    sign_in @admin

    post reset_password_admin_user_path(@admin)

    assert_redirected_to admin_users_path
    assert_match(/Cannot reset your own password/, flash[:alert])
  end

  test 'admin cannot reset own password via JSON request' do
    sign_in @admin

    post reset_password_admin_user_path(@admin), as: :json

    assert_response :forbidden

    json_response = JSON.parse(response.body)

    assert_equal false, json_response['success']
    assert_match(/Cannot reset your own password/, json_response['error'])
  end

  test 'non-admin cannot access reset password functionality' do
    sign_in @editor

    get admin_users_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]

    # Try to directly call reset password action
    post reset_password_admin_user_path(@user)
    # Should be redirected due to authorization failure
    assert_response :redirect
  end

  test 'multiple password resets generate different passwords' do
    sign_in @admin

    # Reset password for first user
    post reset_password_admin_user_path(@user), as: :json
    first_password = JSON.parse(response.body)['password']

    # Reset password for same user again
    post reset_password_admin_user_path(@user), as: :json
    second_password = JSON.parse(response.body)['password']

    # Passwords should be different each time
    assert_not_equal first_password, second_password
  end

  test 'reset password works with existing users having roles and groups' do
    sign_in @admin

    # Create a user with groups
    group = Group.create!(name: "Test Group #{SecureRandom.hex(4)}")
    @user.groups << group

    original_password = @user.encrypted_password

    # Reset their password
    post reset_password_admin_user_path(@user)

    assert_redirected_to admin_users_path
    assert_match(/Temporary password generated/, flash[:notice])

    # User should still have their groups after password reset
    @user.reload

    assert_includes @user.groups, group

    # User should still have their role
    assert_equal 'regular', @user.role

    # Password should be changed
    assert_not_equal original_password, @user.encrypted_password
  end

  test 'temporary password is secure' do
    sign_in @admin

    post reset_password_admin_user_path(@user), as: :json
    password = JSON.parse(response.body)['password']

    # Should be at least 12 characters (as defined in User model)
    assert_operator password.length, :>=, 12, "Password should be at least 12 characters"

    # Should contain letters
    assert_match(/[a-zA-Z]/, password, "Password should contain letters")

    # Should contain numbers
    assert_match(/[0-9]/, password, "Password should contain numbers")
  end

  test 'temporary password allows user to sign in' do
    sign_in @admin

    # Generate temporary password
    post reset_password_admin_user_path(@user), as: :json
    temp_password = JSON.parse(response.body)['password']

    # Sign out admin
    sign_out @admin

    # User should be able to sign in with temporary password
    post user_session_path, params: {
      user: {
        email: @user.email,
        password: temp_password
      }
    }

    # Should redirect to root (successful login)
    assert_redirected_to root_path
  end

  test 'reset password for multiple users works correctly' do
    sign_in @admin

    user_original = @user.encrypted_password
    editor_original = @editor.encrypted_password

    # Reset password for first user
    post reset_password_admin_user_path(@user)

    assert_redirected_to admin_users_path

    # Reset password for second user
    post reset_password_admin_user_path(@editor)

    assert_redirected_to admin_users_path

    # Both passwords should be changed
    @user.reload
    @editor.reload

    assert_not_equal user_original, @user.encrypted_password
    assert_not_equal editor_original, @editor.encrypted_password
  end
end
