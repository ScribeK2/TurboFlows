# The "send test email" button on Admin -> Email. Its whole job is to exercise
# the configured relay end to end — From, credentials, TLS — without waiting for
# someone to forget a password.
class SmtpTestMailer < ApplicationMailer
  def test_email(recipient, sent_by:)
    @sent_by = sent_by
    mail(to: recipient, subject: "TurboFlows SMTP test") do |format|
      format.text do
        render plain: <<~BODY
          This is a test message from TurboFlows.

          If you are reading it, the SMTP settings saved by #{sent_by} work:
          the relay accepted the message and delivered it.

          Sent at #{Time.current.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}.
        BODY
      end
    end
  end
end
