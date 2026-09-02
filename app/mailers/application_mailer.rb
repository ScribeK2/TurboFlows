# Base for TurboFlows' own mailers. Carries the administrator's runtime SMTP
# settings; Devise's mailer cannot inherit from here, so TurboFlowsDeviseMailer
# includes the same concern directly.
class ApplicationMailer < ActionMailer::Base
  include RuntimeSmtpDelivery
end
