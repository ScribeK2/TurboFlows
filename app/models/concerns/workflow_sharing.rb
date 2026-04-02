# Handles sharing and embedding logic for workflows.
# Manages share tokens and embeddability checks.
module WorkflowSharing
  extend ActiveSupport::Concern

  def generate_share_token!
    update!(share_token: SecureRandom.urlsafe_base64(18))
  end

  def revoke_share_token!
    update!(share_token: nil)
  end

  def shared?
    share_token.present?
  end

  def embeddable?
    shared? && embed_enabled?
  end
end
