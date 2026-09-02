# A boolean could only say "STARTTLS or nothing", so an implicit-TLS relay on
# port 465 was unreachable: the client spoke plaintext to a TLS-only port and
# both ends waited until the read timed out. The mail gem treats tls/ssl and
# enable_starttls as mutually exclusive and raises when both are set, so the
# choice is genuinely three-way and belongs in one column.
class ReplaceSmtpStarttlsFlagWithEncryption < ActiveRecord::Migration[8.1]
  def up
    add_column :smtp_settings, :encryption, :string, default: "starttls", null: false
    # Raw SQL rather than the model: a model in a migration binds to whatever
    # schema it loads under, which is not the one being migrated.
    execute <<~SQL.squish
      UPDATE smtp_settings
      SET encryption = CASE WHEN enable_starttls THEN 'starttls' ELSE 'none' END
    SQL
    remove_column :smtp_settings, :enable_starttls
  end

  def down
    add_column :smtp_settings, :enable_starttls, :boolean, default: true, null: false
    execute <<~SQL.squish
      UPDATE smtp_settings
      SET enable_starttls = CASE WHEN encryption = 'starttls' THEN #{quoted_true} ELSE #{quoted_false} END
    SQL
    remove_column :smtp_settings, :encryption
  end

  private

  def quoted_true
    connection.quoted_true
  end

  def quoted_false
    connection.quoted_false
  end
end
