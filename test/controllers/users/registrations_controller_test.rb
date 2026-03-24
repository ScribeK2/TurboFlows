require "test_helper"

module Users
  class RegistrationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(
        email: "reg-user-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "editor",
        display_name: "Original Name"
      )
      sign_in @user
    end

    # 1. update display_name without current_password
    test "update display_name without current_password succeeds" do
      put user_registration_path,
          params: { user: { display_name: "New Display Name" } }

      assert_redirected_to edit_user_registration_path
      @user.reload
      assert_equal "New Display Name", @user.display_name
    end

    # 2. update email requires current_password
    test "update email with correct current_password succeeds" do
      new_email = "new-email-#{SecureRandom.hex(4)}@example.com"

      put user_registration_path,
          params: {
            user: {
              email: new_email,
              current_password: "password123!"
            }
          }

      assert_redirected_to edit_user_registration_path
      @user.reload
      assert_equal new_email, @user.email
    end

    # 3. update password requires current_password
    test "update password with correct current_password succeeds" do
      put user_registration_path,
          params: {
            user: {
              password: "newpassword456!",
              password_confirmation: "newpassword456!",
              current_password: "password123!"
            }
          }

      assert_redirected_to edit_user_registration_path
      @user.reload
      assert @user.valid_password?("newpassword456!")
    end

    # 4. redirects to edit page after update
    test "redirects to edit_user_registration_path after display_name update" do
      put user_registration_path,
          params: { user: { display_name: "Redirect Test" } }

      assert_redirected_to edit_user_registration_path
    end

    # 5. rejects display_name exceeding 50-character maximum
    test "rejects display_name longer than 50 characters" do
      long_name = "A" * 256

      put user_registration_path,
          params: { user: { display_name: long_name } }

      # Validation fails — should render edit (not redirect) or redirect with error
      @user.reload
      # display_name should NOT have been updated to the invalid value
      assert_not_equal long_name, @user.display_name
    end
  end
end
