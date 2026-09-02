require "test_helper"

class SmtpSettingTest < ActiveSupport::TestCase
  setup { SmtpSetting.delete_all }

  def build(**overrides)
    SmtpSetting.new({ address: "smtp.example.com", port: 587, authentication: "plain",
                      user_name: "mailer", password: "s3cret", encryption: "starttls",
                      enabled: true }.merge(overrides))
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
  end

  test "delivery options omit credentials for a no-auth relay" do
    options = build(authentication: "none", user_name: nil, password: nil,
                    encryption: "none", port: 25).delivery_options

    assert_nil options[:authentication]
    assert_not options.key?(:user_name)
    assert_not options.key?(:password)
  end

  # TLS and STARTTLS are separate mechanisms and the mail gem raises when both
  # are set. Emitting both keys is the bug that made a port 465 relay time out,
  # so each mode is pinned to the exact key it produces.

  test "implicit TLS emits tls and never a starttls key" do
    options = build(encryption: "tls", port: 465).delivery_options

    assert options[:tls]
    assert_not options.key?(:enable_starttls), "tls and enable_starttls are mutually exclusive"
  end

  test "starttls emits :always and never a tls key" do
    options = build(encryption: "starttls").delivery_options

    assert_equal :always, options[:enable_starttls], ":auto would silently send in the clear"
    assert_not options.key?(:tls)
  end

  test "no encryption emits a false starttls and never a tls key" do
    options = build(encryption: "none", port: 25).delivery_options

    assert options.key?(:enable_starttls), "the key is emitted explicitly, not left absent"
    assert_not options[:enable_starttls]
    assert_not options.key?(:tls)
  end

  test "encryption must be a known mode" do
    assert_not build(encryption: "sslv3").valid?
    SmtpSetting::ENCRYPTION_MODES.each { |m| assert_predicate build(encryption: m), :valid? }
  end
end
