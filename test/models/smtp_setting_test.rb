require "test_helper"

class SmtpSettingTest < ActiveSupport::TestCase
  setup { SmtpSetting.delete_all }

  def build(**overrides)
    SmtpSetting.new({ address: "smtp.example.com", port: 587, authentication: "plain",
                      user_name: "mailer", password: "s3cret", enabled: true }.merge(overrides))
  end

  # -- validation --

  test "a disabled draft saves even when incomplete" do
    assert build(address: nil, user_name: nil, enabled: false).save
  end

  test "enabling requires a host" do
    setting = build(address: nil)
    assert_not setting.valid?
    assert_includes setting.errors[:address], "can't be blank"
  end

  test "enabling with authentication requires a username" do
    setting = build(user_name: nil)
    assert_not setting.valid?
    assert_includes setting.errors[:user_name], "can't be blank"
  end

  test "no-auth relay does not require a username" do
    assert_predicate build(authentication: "none", user_name: nil, password: nil), :valid?
  end

  test "port must be a real port" do
    assert_not build(port: 0).valid?
    assert_not build(port: 70_000).valid?
    assert_predicate build(port: 25), :valid?
  end

  test "authentication must be a known method" do
    assert_not build(authentication: "kerberos").valid?
  end

  test "from_address must look like an email when given" do
    assert_not build(from_address: "not-an-email").valid?
    assert_predicate build(from_address: ""), :valid?
  end

  # -- the secret --

  test "password is encrypted at rest" do
    setting = build
    setting.save!

    stored = SmtpSetting.connection.select_value(
      "SELECT password FROM smtp_settings WHERE id = #{setting.id}"
    )
    assert_not_equal "s3cret", stored
    assert_no_match(/s3cret/, stored.to_s)
    assert_equal "s3cret", setting.reload.password
  end

  # -- what the mailers ask --

  test "active is nil until a complete setting is enabled" do
    assert_nil SmtpSetting.active

    setting = build(enabled: false)
    setting.save!
    assert_nil SmtpSetting.active, "disabled settings must not take over mail"

    setting.update!(enabled: true)
    assert_equal setting, SmtpSetting.active
  end

  test "current returns an unsaved singleton when none exists" do
    assert_predicate SmtpSetting.current, :new_record?
  end

  test "delivery options carry credentials for an authenticated relay" do
    options = build(domain: nil).delivery_options

    assert_equal "smtp.example.com", options[:address]
    assert_equal 587, options[:port]
    assert_equal "smtp.example.com", options[:domain], "falls back to the host"
    assert_equal "plain", options[:authentication]
    assert_equal "mailer", options[:user_name]
    assert_equal "s3cret", options[:password]
    assert options[:enable_starttls]
  end

  test "delivery options omit credentials for a no-auth relay" do
    options = build(authentication: "none", user_name: nil, password: nil,
                    enable_starttls: false, port: 25).delivery_options

    assert_nil options[:authentication]
    assert_not options.key?(:user_name)
    assert_not options.key?(:password)
    assert_not options[:enable_starttls]
  end
end
