# Runtime SMTP configuration, edited by an administrator at Admin -> Email.
#
# This exists because the people who run a TurboFlows install are not always the
# people who deploy it: SMTP_ADDRESS and friends in config/environments/production.rb
# still work and stay the way to configure mail as code, but they need a redeploy
# and shell access to change. A row here overrides them once enabled, so an admin
# can point the app at a relay without either.
#
# Only one row is ever used. `current` is the editable singleton, `active` is the
# narrower question the mailers ask: is there a usable configuration right now?
class SmtpSetting < ApplicationRecord
  encrypts :password

  AUTHENTICATION_METHODS = %w[plain login cram_md5 none].freeze

  # Only meaningful once enabled — a half-filled draft should still save, so the
  # admin can come back to it, but it must be complete before it takes over mail.
  validates :address, presence: true, if: :enabled?
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }
  validates :authentication, inclusion: { in: AUTHENTICATION_METHODS }
  validates :from_address, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :user_name, presence: true, if: :authenticated?

  def self.current
    order(:id).first || new
  end

  # What the mailers consult. nil means "nothing configured here", which leaves
  # the environment's own delivery settings untouched.
  def self.active
    setting = order(:id).first
    setting if setting&.usable?
  end

  def usable?
    enabled? && address.present?
  end

  def authenticated?
    enabled? && authentication != "none"
  end

  # Mail's smtp delivery options. Note this is handed to
  # message.delivery_method(:smtp, ...), which replaces the delivery method
  # outright — merging into the environment's settings would inherit sendmail
  # whenever SMTP_ADDRESS was never set, which is the common case here.
  def delivery_options
    options = {
      address: address,
      port: port,
      domain: domain.presence || address,
      enable_starttls: enable_starttls?
    }

    if authentication == "none"
      options[:authentication] = nil
    else
      options[:authentication] = authentication
      options[:user_name] = user_name.presence
      options[:password] = password.presence
    end

    options
  end
end
