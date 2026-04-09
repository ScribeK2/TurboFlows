# frozen_string_literal: true

require 'test_helper'

module Workflows
  class StepSyncsControllerTest < ActionDispatch::IntegrationTest
    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "editor-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'editor'
      )
      @workflow = Workflow.create!(title: 'Sync Flow', user: @editor)
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test 'update with valid data returns JSON success' do
      step_uuid = SecureRandom.uuid
      patch workflow_step_sync_path(@workflow), params: {
        lock_version: @workflow.lock_version,
        steps: [
          { id: step_uuid, type: 'question', title: 'First?', question: 'What?', answer_type: 'text' },
          { id: SecureRandom.uuid, type: 'resolve', title: 'Done', resolution_type: 'success' }
        ],
        start_node_uuid: step_uuid
      }, as: :json

      assert_response :success
      json = response.parsed_body

      assert json['success']
      assert_predicate json['lock_version'], :present?
    end

    test 'update with stale lock_version returns 409 conflict' do
      patch workflow_step_sync_path(@workflow), params: {
        lock_version: @workflow.lock_version + 999,
        steps: [
          { id: SecureRandom.uuid, type: 'resolve', title: 'Done', resolution_type: 'success' }
        ]
      }, as: :json

      assert_response :conflict
      json = response.parsed_body

      assert_match(/modified by another user/i, json['error'])
    end

    test 'update requires authentication' do
      sign_out @editor
      patch workflow_step_sync_path(@workflow), params: {
        lock_version: @workflow.lock_version,
        steps: []
      }, as: :json

      assert_response :unauthorized
    end
  end
end
