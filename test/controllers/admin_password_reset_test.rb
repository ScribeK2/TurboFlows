require 'test_helper'

class AdminPasswordResetTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: 'admin-test@example.com',
      password: 'password123!',
      role: 'admin'
    )
    @user = User.create!(
      email: 'user-test@example.com',
      password: 'password123!',
      role: 'user'
    )
  end

  test 'generate_temporary_password creates secure password' do
    original_password = @user.encrypted_password

    temp_password = @user.generate_temporary_password

    @user.reload

    assert_not_equal original_password, @user.encrypted_password
    assert_not_nil temp_password
    assert_operator temp_password.length, :>=, 8, "Password should be at least 8 characters"
    assert_match(/[a-zA-Z]/, temp_password, "Password should contain letters")
    assert_match(/[0-9]/, temp_password, "Password should contain numbers")
  end

  test 'generate_temporary_password allows user to authenticate with new password' do
    temp_password = @user.generate_temporary_password

    # User should be able to authenticate with the new password
    assert @user.valid_password?(temp_password), "User should be able to authenticate with temporary password"
  end

  test 'admin can reset user password via controller' do
    sign_in @admin

    original_password = @user.encrypted_password

    post reset_password_admin_user_path(@user)

    assert_redirected_to admin_users_path
    assert_match(/Temporary password generated for #{@user.email}/, flash[:notice])

    @user.reload

    assert_not_equal original_password, @user.encrypted_password
  end
end
