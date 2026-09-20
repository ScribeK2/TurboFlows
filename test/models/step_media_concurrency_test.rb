require "test_helper"

# Two tabs attaching to one step at the same instant. `attach` is a
# read-modify-write on the attachment list, so both read it as it was and one
# file is lost. The per-controller queue in media_attachments_controller.js
# closed this for several files chosen in ONE panel and cannot see another tab.
#
# It drives Step#attach_media - the seam the controller itself calls - rather
# than taking a lock of its own around a bare `attach`. A test that locked for
# itself would pass with the lock removed from the model, proving only that row
# locks work.
#
# PostgreSQL only: SQLite ignores FOR UPDATE and serialises every writer anyway,
# so locally this can neither fail nor prove anything. To run it:
#
#   docker run -d --rm --name tf-pg -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:55432:5432 postgres:16
#   export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/turboflows_test
#   RAILS_ENV=test bin/rails db:create db:schema:load
#   bin/rails test test/models/step_media_concurrency_test.rb
#
# Real threads on real connections, so nothing here can run inside the usual
# test transaction: records are committed and removed in teardown.
class StepMediaConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ATTACHES = 4

  setup do
    skip "PostgreSQL only: SQLite serialises writers, so the race cannot occur" unless
      ActiveRecord::Base.connection.adapter_name.match?(/postg/i)

    @user = User.create!(email: "media-race-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!",
                         role: "editor")
    @workflow = Workflow.create!(title: "Media Race WF", user: @user)
    @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Attach here")
  end

  teardown do
    Step.find_by(id: @step&.id)&.destroy
    Workflow.find_by(id: @workflow&.id)&.destroy
    User.find_by(id: @user&.id)&.destroy
  end

  test "concurrent attaches all land" do
    blobs = Array.new(ATTACHES) do |i|
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("file #{i}"), filename: "f#{i}.txt", content_type: "image/png"
      )
    end

    barrier = Concurrent::CyclicBarrier.new(ATTACHES) if defined?(Concurrent::CyclicBarrier)

    threads = blobs.map do |blob|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier&.wait(5)
          Step.find(@step.id).attach_media(blob)
        end
      end
    end
    threads.each(&:join)

    assert_equal ATTACHES, @step.reload.media_attachments.count,
                 "a read-modify-write with no row lock loses attachments"
  end
end
