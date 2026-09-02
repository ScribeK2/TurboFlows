require "test_helper"

class UserDeviseNotificationsTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    ActiveRecord::Base.connection.disable_referential_integrity { User.delete_all }
    @user = User.create!(email: "mailer@example.com", password: "password123!",
                         password_confirmation: "password123!")
  end

  # The point of the change: nothing blocks the request on SMTP any more.
  test "password reset instructions are queued, not delivered inline" do
    assert_no_difference "ActionMailer::Base.deliveries.size" do
      assert_enqueued_emails 1 do
        @user.send_reset_password_instructions
      end
    end
  end

  test "unlock instructions are queued when the account locks" do
    assert_enqueued_emails 1 do
      Devise.maximum_attempts.times { @user.failed_attempts += 1 }
      @user.lock_access!
    end
    assert_predicate @user, :access_locked?
  end

  # A password change notifies from an after_update. changed? is already false
  # there, so this one enqueues inline rather than via the pending queue — it
  # still must go out, and exactly once.
  test "password change notification is queued exactly once" do
    assert_enqueued_emails 1 do
      @user.update!(password: "newpassword456!", password_confirmation: "newpassword456!")
    end
  end

  # The admin temp-password path opts out; it shows the password in the UI.
  test "admin temporary password reset queues no mail" do
    assert_no_enqueued_emails do
      @user.generate_temporary_password
    end
  end

  # Guards the reason for the deferred pattern: the job must never be enqueued
  # while the record still has uncommitted changes.
  test "no notification is enqueued before the record is committed" do
    user = User.new(email: "pending@example.com", password: "password123!",
                    password_confirmation: "password123!")
    assert_no_enqueued_emails do
      user.send(:send_devise_notification, :reset_password_instructions, "tok", {})
    end
    assert_equal 1, user.send(:pending_devise_notifications).size
  end
end
