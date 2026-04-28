require "test_helper"

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "profile-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      display_name: "Original Name",
      time_zone: "UTC"
    )
    sign_in @user
  end

  # -- Authentication --

  test "should require authentication" do
    sign_out @user
    get edit_profile_path
    assert_redirected_to new_user_session_path
  end

  # -- Edit --

  test "edit renders form with current values" do
    get edit_profile_path
    assert_response :success
    assert_select "input[name='user[display_name]'][value=?]", "Original Name"
    assert_select "select[name='user[time_zone]']"
    # Email shown as a disabled, read-only field
    assert_select "input[disabled]", value: @user.email
  end

  test "edit shows current local time hint" do
    @user.update!(time_zone: "Asia/Tokyo")
    travel_to Time.utc(2026, 4, 28, 0, 30) do # 09:30 JST
      get edit_profile_path
      assert_response :success
      assert_select ".form-hint", text: /9:30 AM/
    end
  end

  # -- Update --

  test "update saves a new display name" do
    patch profile_path, params: { user: { display_name: "New Name", time_zone: @user.time_zone } }
    assert_redirected_to edit_profile_path
    assert_equal "New Name", @user.reload.display_name
    follow_redirect!
    assert_select ".flash--notice", text: /Profile updated/
  end

  test "update saves a new time zone" do
    patch profile_path, params: { user: { display_name: @user.display_name, time_zone: "Asia/Tokyo" } }
    assert_redirected_to edit_profile_path
    # Stored as the Rails-canonical friendly name (the form uses these as option values).
    assert_equal "Tokyo", @user.reload.time_zone
  end

  test "update accepts a Rails-friendly time zone name" do
    patch profile_path, params: { user: { display_name: @user.display_name, time_zone: "Pacific Time (US & Canada)" } }
    assert_redirected_to edit_profile_path
    assert_equal "Pacific Time (US & Canada)", @user.reload.time_zone
  end

  test "update strips whitespace and canonicalizes to the friendly name" do
    patch profile_path, params: { user: { display_name: "  Casey  ", time_zone: "  Asia/Tokyo  " } }
    @user.reload
    assert_equal "Casey", @user.display_name
    assert_equal "Tokyo", @user.time_zone
  end

  test "update rejects an unrecognized time zone" do
    patch profile_path, params: { user: { display_name: @user.display_name, time_zone: "Not/A/Zone" } }
    assert_response :unprocessable_content
    assert_equal "UTC", @user.reload.time_zone
    assert_select ".flash--alert", text: /not a recognized time zone/
  end

  test "update rejects a blank time zone" do
    patch profile_path, params: { user: { display_name: @user.display_name, time_zone: "" } }
    assert_response :unprocessable_content
    assert_equal "UTC", @user.reload.time_zone
  end

  test "update does not allow setting role via mass assignment" do
    assert_equal "regular", @user.role
    patch profile_path, params: { user: { display_name: "x", time_zone: "UTC", role: "admin" } }
    assert_equal "regular", @user.reload.role
  end

  test "update does not allow changing email" do
    original_email = @user.email
    patch profile_path, params: { user: { display_name: "x", time_zone: "UTC", email: "hacker@example.com" } }
    assert_equal original_email, @user.reload.email
  end

  # -- Layout integration --

  test "navigation dropdown links to profile" do
    get root_path
    assert_response :success
    assert_select "a[href=?]", edit_profile_path, text: /Profile/
  end
end
