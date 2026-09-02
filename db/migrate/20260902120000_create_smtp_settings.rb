class CreateSmtpSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :smtp_settings do |t|
      t.string  :address
      t.integer :port, default: 587, null: false
      t.string  :domain
      t.string  :user_name
      # Encrypted at rest by Active Record Encryption, so it is stored as
      # ciphertext plus its envelope and needs more room than the plaintext.
      t.text    :password
      t.string  :authentication, default: "plain", null: false
      t.boolean :enable_starttls, default: true, null: false
      t.string  :from_address
      t.boolean :enabled, default: false, null: false

      t.timestamps
    end
  end
end
