# Applies the administrator's SMTP settings to a message as it is sent.
#
# Deliberately per-message rather than assigning ActionMailer::Base.smtp_settings
# once: Puma runs several workers, and a process-global write only reaches the
# one that handled the form. Reading the row at send time means every worker, and
# every Solid Queue job, uses the current settings with no restart.
#
# Lives in app/mailers rather than app/mailers/concerns because only
# app/models/concerns and app/controllers/concerns are autoload roots by default;
# under concerns/ this would have to be named Concerns::RuntimeSmtpDelivery.
module RuntimeSmtpDelivery
  extend ActiveSupport::Concern

  included do
    after_action :apply_runtime_smtp_settings
  end

  private

  def apply_runtime_smtp_settings
    setting = SmtpSetting.active
    return if setting.nil?

    message.delivery_method(:smtp, setting.delivery_options)
    message.from = setting.from_address if setting.from_address.present?
  end
end
