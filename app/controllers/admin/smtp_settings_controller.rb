module Admin
  class SmtpSettingsController < BaseController
    before_action :set_smtp_setting

    def show; end

    def update
      @smtp_setting.assign_attributes(smtp_setting_params)

      if @smtp_setting.save
        audit("updated SMTP settings (host: #{@smtp_setting.address}, enabled: #{@smtp_setting.enabled?})")
        redirect_to admin_smtp_setting_path, notice: "Email settings saved."
      else
        render :show, status: :unprocessable_content
      end
    end

    # Sends a real message through the saved settings. Delivered inline on
    # purpose: the whole point is to report back what the relay said, and
    # deliver_later would hand the admin a queued job instead of an answer.
    #
    # perform_deliveries and raise_delivery_errors are forced for this one
    # message rather than trusted from the environment. raise_delivery_errors is
    # only switched on inside production.rb's SMTP_ADDRESS branch, which is
    # exactly the branch that does not run when mail is configured from this
    # page — so a refused connection would come back as "Test message sent" and
    # the button would certify a relay that does not work.
    def test_delivery
      recipient = params[:recipient].presence || current_user.email
      mail = SmtpTestMailer.test_email(recipient, sent_by: current_user.email).message
      mail.perform_deliveries = true
      mail.raise_delivery_errors = true
      mail.deliver
      audit("sent an SMTP test message to #{recipient}")
      redirect_to admin_smtp_setting_path, notice: "Test message sent to #{recipient}."
    rescue StandardError => e
      audit("SMTP test to #{recipient} failed: #{e.class}")
      redirect_to admin_smtp_setting_path, alert: "Test failed: #{e.class}: #{e.message}"
    end

    private

    def set_smtp_setting
      @smtp_setting = SmtpSetting.current
    end

    def smtp_setting_params
      permitted = params.expect(
        smtp_setting: %i[address port domain user_name password authentication
                         enable_starttls from_address enabled]
      )
      # The form never renders the stored password back, so a blank field means
      # "leave it alone", not "clear it". Only an explicit value replaces it.
      permitted.delete(:password) if permitted[:password].blank?
      permitted
    end

    def audit(message)
      Rails.logger.info "[ADMIN ACTION] #{current_user.email} #{message} from IP: #{request.remote_ip}"
    end
  end
end
