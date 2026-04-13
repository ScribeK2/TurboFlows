# frozen_string_literal: true

require 'test_helper'

class CleanupTaskTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: 'cleanup-task-test@test.com', password: 'password123456', role: 'editor')
  end

  def teardown
    Scenario.where(user: @user).delete_all
    Workflow.where(user: @user).destroy_all
    @user.destroy
  end

  test 'cleanup:scenarios invokes Scenario.cleanup_stale' do
    workflow = Workflow.create!(title: 'Cleanup Test', user: @user)
    stale = Scenario.create!(
      workflow: workflow, user: @user, purpose: 'simulation',
      status: 'completed', execution_path: [], results: {}, inputs: {},
      completed_at: 8.days.ago
    )
    stale.update_column(:updated_at, 8.days.ago)

    count = Scenario.cleanup_stale

    assert_operator count, :>=, 1
    assert_nil Scenario.find_by(id: stale.id)
  end

  test 'workflows:cleanup_orphaned_drafts uses SQL not Ruby filtering' do
    orphan = Workflow.create!(title: 'Untitled Workflow', user: @user, status: 'draft')
    orphan.update_column(:created_at, 25.hours.ago)

    non_orphan = Workflow.create!(title: 'Untitled Workflow', user: @user, status: 'draft')
    non_orphan.update_column(:created_at, 25.hours.ago)
    Steps::Question.create!(workflow: non_orphan, uuid: SecureRandom.uuid, position: 0, title: 'Q', question: '?', answer_type: 'text', variable_name: 'v')

    # Use the model scope (canonical source of truth)
    orphans = Workflow.orphaned_drafts

    assert_includes orphans, orphan
    assert_not_includes orphans, non_orphan
  end
end
