# TurboFlows keeps exactly one secret in the database: the SMTP password an
# administrator types into Admin -> Email. Active Record Encryption needs three
# keys to protect it.
#
# Rather than make an operator set and keep three more variables in sync, derive
# them from secret_key_base, which every deployment already has. Credentials win
# when they carry the keys, so an install that would rather manage them
# explicitly still can — run `bin/rails db:encryption:init` and paste the result
# into credentials.
#
# The trade-off of deriving: rotating secret_key_base makes the stored SMTP
# password undecryptable. Nothing else is encrypted, so recovery is an admin
# re-entering it on the settings page.
#
# Assigns ActiveRecord::Encryption.config rather than config.active_record.encryption
# because this file runs after the railtie has already read the latter. Keys are
# resolved lazily, at encrypt/decrypt time, so setting them here is in time.
Rails.application.config.after_initialize do
  from_credentials = Rails.application.credentials.active_record_encryption
  next if from_credentials.present? && from_credentials[:primary_key].present?

  generator = ActiveSupport::KeyGenerator.new(
    Rails.application.secret_key_base,
    hash_digest_class: OpenSSL::Digest::SHA256
  )

  ActiveRecord::Encryption.config.primary_key =
    generator.generate_key("turboflows active record encryption primary key", 32)
  ActiveRecord::Encryption.config.deterministic_key =
    generator.generate_key("turboflows active record encryption deterministic key", 32)
  ActiveRecord::Encryption.config.key_derivation_salt =
    generator.generate_key("turboflows active record encryption key derivation salt", 32)
end
