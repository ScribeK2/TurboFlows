require "test_helper"

class RuntimeSmtpDeliveryTest < ActionMailer::TestCase
  setup do
    SmtpSetting.delete_all
    @user = User.create!(email: "recipient@example.com", password: "password123!",
                         password_confirmation: "password123!")
  end

  def enable_relay(**overrides)
    SmtpSetting.create!({ address: "smtp.example.com", port: 2525, domain: "example.com",
                          authentication: "plain", user_name: "mailer", password: "s3cret",
                          encryption: "starttls", enabled: true }.merge(overrides))
  end

  def devise_message
    TurboFlowsDeviseMailer.reset_password_instructions(@user, "reset-token").message
  end

  test "with nothing configured the environment's delivery is left alone" do
    message = devise_message

    assert_not_equal Mail::SMTP, message.delivery_method.class
    assert_equal ["test@example.com"], message.from, "keeps the environment default From"
  end

  test "an enabled relay is applied to Devise mail" do
    enable_relay
    message = devise_message

    assert_instance_of Mail::SMTP, message.delivery_method
    settings = message.delivery_method.settings
    assert_equal "smtp.example.com", settings[:address]
    assert_equal 2525, settings[:port]
    assert_equal "mailer", settings[:user_name]
    assert_equal "s3cret", settings[:password]
  end

  test "a disabled relay is not applied" do
    enable_relay(enabled: false)
    assert_not_equal Mail::SMTP, devise_message.delivery_method.class
  end

  test "from_address overrides the environment default when set" do
    enable_relay(from_address: "helpdesk@example.com")
    assert_equal ["helpdesk@example.com"], devise_message.from
  end

  test "a blank from_address leaves the environment default in place" do
    enable_relay(from_address: nil)
    assert_equal ["test@example.com"], devise_message.from
  end

  # The settings are read per message, so a change reaches every worker and
  # every queued job without a restart.
  test "editing the relay changes the next message with no restart" do
    setting = enable_relay
    assert_equal "smtp.example.com", devise_message.delivery_method.settings[:address]

    setting.update!(address: "relay2.example.com")
    assert_equal "relay2.example.com", devise_message.delivery_method.settings[:address]
  end
end
