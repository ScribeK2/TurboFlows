# Devise's mailer, with the administrator's SMTP settings applied at send time.
# Wired up through config.mailer in config/initializers/devise.rb. Devise's own
# templates still render: _prefixes keeps devise/mailer on the lookup path.
class TurboFlowsDeviseMailer < Devise::Mailer
  include RuntimeSmtpDelivery
end
