require "test_helper"

class Admin::SmtpSettingsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    SmtpSetting.delete_all
    @admin = User.create!(email: "smtp-admin@example.com", password: "password123!", role: "admin")
    @editor = User.create!(email: "smtp-editor@example.com", password: "password123!", role: "editor")
  end

  def valid_params(**overrides)
    { smtp_setting: { address: "smtp.example.com", port: 587, domain: "example.com",
                      authentication: "plain", user_name: "mailer", password: "s3cret",
                      enable_starttls: "1", from_address: "turboflows@example.com",
                      enabled: "1" }.merge(overrides) }
  end

  # -- authorization --

  test "an admin can open the page" do
    sign_in @admin
    get admin_smtp_setting_path
    assert_response :success
    assert_select "h1", "Email"
  end

  test "a non-admin cannot" do
    sign_in @editor
    get admin_smtp_setting_path
    assert_redirected_to root_path
  end

  test "an anonymous visitor cannot" do
    get admin_smtp_setting_path
    assert_redirected_to new_user_session_path
  end

  test "a non-admin cannot write settings" do
    sign_in @editor
    assert_no_difference "SmtpSetting.count" do
      patch admin_smtp_setting_path, params: valid_params
    end
    assert_redirected_to root_path
  end

  # -- saving --

  test "saving creates the singleton" do
    sign_in @admin
    assert_difference "SmtpSetting.count", 1 do
      patch admin_smtp_setting_path, params: valid_params
    end
    assert_redirected_to admin_smtp_setting_path

    setting = SmtpSetting.current
    assert_equal "smtp.example.com", setting.address
    assert_equal "s3cret", setting.password
    assert_predicate setting, :enabled?
  end

  test "saving again edits the same row rather than adding one" do
    sign_in @admin
    patch admin_smtp_setting_path, params: valid_params
    assert_no_difference "SmtpSetting.count" do
      patch admin_smtp_setting_path, params: valid_params(address: "relay.example.com")
    end
    assert_equal "relay.example.com", SmtpSetting.current.address
  end

  test "invalid settings re-render with errors and save nothing" do
    sign_in @admin
    assert_no_difference "SmtpSetting.count" do
      patch admin_smtp_setting_path, params: valid_params(address: "")
    end
    assert_response :unprocessable_content
    assert_select ".form-error"
  end

  # -- the write-only password --

  test "a blank password keeps the stored one" do
    sign_in @admin
    patch admin_smtp_setting_path, params: valid_params
    assert_equal "s3cret", SmtpSetting.current.password

    patch admin_smtp_setting_path, params: valid_params(password: "", user_name: "changed")
    setting = SmtpSetting.current
    assert_equal "changed", setting.user_name, "the rest of the form still saves"
    assert_equal "s3cret", setting.password, "blank means keep, not clear"
  end

  test "a new password replaces the stored one" do
    sign_in @admin
    patch admin_smtp_setting_path, params: valid_params
    patch admin_smtp_setting_path, params: valid_params(password: "rotated")
    assert_equal "rotated", SmtpSetting.current.password
  end

  test "the stored password is never rendered back" do
    sign_in @admin
    patch admin_smtp_setting_path, params: valid_params
    get admin_smtp_setting_path
    assert_response :success
    assert_no_match(/s3cret/, response.body)
  end

  # -- test delivery --

  test "the test button sends a message now, not later" do
    sign_in @admin
    assert_no_enqueued_emails do
      assert_difference "ActionMailer::Base.deliveries.size", 1 do
        post test_delivery_admin_smtp_setting_path, params: { recipient: "ops@example.com" }
      end
    end
    assert_redirected_to admin_smtp_setting_path
    assert_equal ["ops@example.com"], ActionMailer::Base.deliveries.last.to
  end

  test "the test defaults to the signed-in admin" do
    sign_in @admin
    post test_delivery_admin_smtp_setting_path, params: { recipient: "" }
    assert_equal [@admin.email], ActionMailer::Base.deliveries.last.to
  end

  # Points at a port nothing listens on, so the relay refuses the connection
  # immediately. Exercises the real rescue rather than a stub, and proves the
  # saved settings actually reach the message.
  test "a failing relay reports back instead of erroring" do
    sign_in @admin
    SmtpSetting.create!(address: "127.0.0.1", port: 1, authentication: "none",
                        enable_starttls: false, enabled: true)

    post test_delivery_admin_smtp_setting_path, params: { recipient: "ops@example.com" }

    assert_redirected_to admin_smtp_setting_path
    assert_match(/Test failed/, flash[:alert])
    assert_match(/Errno::ECONNREFUSED|Connection refused/, flash[:alert])
  end
end
