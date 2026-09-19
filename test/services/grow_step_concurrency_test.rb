require "test_helper"

# Two grows from one parent landing at the same moment. Each reads the workflow
# before the other has committed, so without a lock both shift the same rows and
# both insert at parent.position + 1 - and two presses of one door both find it
# a stub. GrowStep takes a row lock on the workflow for the length of its
# transaction.
#
# PostgreSQL only: SQLite ignores FOR UPDATE and serialises every writer anyway,
# so locally these can neither fail nor prove anything. To run them:
#
#   docker run -d --rm --name tf-pg -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:55432:5432 postgres:16
#   export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/turboflows_test
#   RAILS_ENV=test bin/rails db:create db:schema:load
#   bin/rails test test/services/grow_step_concurrency_test.rb
#
# Real threads on real connections, so nothing here can run inside the usual
# test transaction: records are committed and removed in teardown - which has
# to find the workflow FRESH, because a grow on another thread assigned its
# start step and this test's own copy never heard, so destroying the stale
# copy skips Workflow#nullify_start_step and trips the foreign key.
#
# Not covered: a grow from a door SHADOWED by a default edge. GrowStep settles
# the order before it takes the lock; the settle is idempotent and its sort is
# deterministic, so two at once converge, but nothing here proves it.
class GrowStepConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 4

  setup do
    skip "row locks need PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    @user = User.create!(email: "grow-race-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Grow race", user: @user)
  end

  # Found fresh: a grow on another thread assigned the start step, which this
  # test's own copy of the workflow never heard about.
  teardown do
    Workflow.find_by(id: @workflow&.id)&.destroy
    @user&.destroy
  end

  test "grows from different doors of one parent at the same moment each get their own position" do
    options = (1..THREADS).map { |n| { "label" => "Option #{n}", "value" => "option_#{n}" } }
    parent = Steps::Question.create!(workflow: @workflow, title: "Which?", question: "Which?", position: 1,
                                     answer_type: "multiple_choice", variable_name: "which", options: options)

    results = together do |n|
      GrowStep.create(workflow: Workflow.find(@workflow.id), step_type: "action",
                      from_step: Step.find(parent.id),
                      label: "Option #{n}", condition: "which == 'option_#{n}'")
    end

    assert_empty results.grep(Exception), results.grep(Exception).map(&:message).join("; ")
    positions = @workflow.steps.reload.order(:position).pluck(:position)
    assert_equal positions.uniq, positions, "two steps claimed one position: #{positions.inspect}"
    assert_equal (1..(THREADS + 1)).to_a, positions
  end

  test "one door pressed several times at the same moment grows one step" do
    parent = Steps::Action.create!(workflow: @workflow, title: "Parent", position: 1)

    results = together do |_n|
      GrowStep.create(workflow: Workflow.find(@workflow.id), step_type: "action", from_step: Step.find(parent.id))
    end

    assert_equal 1, results.grep(Step).size, "expected exactly one grow to win: #{results.inspect}"
    assert_equal THREADS - 1, results.grep(GrowStep::Refused).size
    assert_equal 1, parent.transitions.reload.count
    assert_equal 2, @workflow.steps.reload.count
  end

  private

  # Runs the block on THREADS threads released together, each on its own
  # connection, and returns what each one returned or raised.
  def together
    gate = Queue.new
    threads = (1..THREADS).map do |n|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          yield n
        rescue StandardError => e
          e
        end
      end
    end
    THREADS.times { gate << :go }
    threads.map(&:value)
  end
end
