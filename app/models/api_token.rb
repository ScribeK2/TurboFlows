# A personal access token (spec 2026-09-25-api-and-mcp-design §1).
#
# The raw token is shown once, by #plaintext on the instance #issue returns, and
# is never stored: the table holds its SHA-256. A fast unsalted hash is right
# here, not bcrypt: the secret is 256 random bits, so there is nothing to
# brute-force, and lookup has to be by digest.
#
# A token acts as its user and nothing more. `draft` is checked against the
# user's role on every request (#allows?), not only at creation, so demoting an
# Editor quietly leaves their token read-only.
class ApiToken < ApplicationRecord
  PREFIX = "tf_live_".freeze
  SCOPES = %w[read draft].freeze
  EXPIRY_CHOICES = [7, 30, 90].freeze
  DEFAULT_EXPIRY_DAYS = 30
  MAX_LIFETIME = 90.days
  LAST_USED_WRITE_INTERVAL = 1.minute
  BEARER = /\ABearer\s+(\S+)\z/i

  belongs_to :user

  attr_accessor :plaintext

  validates :name, presence: true, length: { maximum: 60 }
  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validate :scopes_are_known
  validate :draft_needs_an_author
  validate :expiry_within_limit, on: :create

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(raw) = Digest::SHA256.hexdigest(raw.to_s)

  def self.raw_from_authorization(header)
    header.to_s[BEARER, 1]
  end

  def self.issue(user:, name:, scopes:, expires_in_days:)
    raw = PREFIX + SecureRandom.urlsafe_base64(32)
    days = expires_in_days.to_i
    token = user.api_tokens.new(
      name: name,
      scopes: Array(scopes).compact_blank.map(&:to_s).uniq,
      token_digest: digest(raw),
      expires_at: days.positive? ? days.days.from_now : nil
    )
    token.plaintext = raw if token.save
    token
  end

  def self.authenticate(raw)
    return nil unless raw.to_s.start_with?(PREFIX)

    token = active.includes(:user).find_by(token_digest: digest(raw))
    token if token&.user&.active_for_authentication?
  end

  def allows?(scope)
    scope = scope.to_s
    return false unless scopes.include?(scope)

    scope != "draft" || user.can_create_workflows?
  end

  def effective_scopes = SCOPES.select { allows?(it) }

  # A conditional write, so a busy token costs one UPDATE a minute rather than
  # one per request.
  def record_use!
    self.class.where(id: id)
        .where("last_used_at IS NULL OR last_used_at < ?", LAST_USED_WRITE_INTERVAL.ago)
        .update_all(last_used_at: Time.current)
  end

  def revoke! = update!(revoked_at: Time.current)

  def state
    return :revoked if revoked_at
    return :expired if expires_at <= Time.current

    :active
  end

  private

  def scopes_are_known
    if scopes.blank?
      errors.add(:scopes, "must include at least one of #{SCOPES.to_sentence}")
    elsif (unknown = scopes - SCOPES).any?
      errors.add(:scopes, "has unknown values: #{unknown.join(', ')}")
    end
  end

  def draft_needs_an_author
    return unless scopes.to_a.include?("draft") && !user&.can_create_workflows?

    errors.add(:scopes, "draft is only for Editors and Administrators")
  end

  def expiry_within_limit
    return if expires_at.blank?
    return if expires_at > Time.current && expires_at <= MAX_LIFETIME.from_now + 1.minute

    errors.add(:expires_at, "must be within #{MAX_LIFETIME.in_days.to_i} days")
  end
end
