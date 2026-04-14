# frozen_string_literal: true

require 'test_helper'

module Workflows
  class ImportsControllerTest < ActionDispatch::IntegrationTest
    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "editor-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'editor'
      )
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test 'new renders import form' do
      get new_workflow_import_path

      assert_response :success
    end

    test 'create with valid JSON creates workflow' do
      json_data = {
        title: 'Imported Flow',
        description: 'A test import',
        graph_mode: true,
        start_node_uuid: 'uuid-1',
        steps: [
          { id: 'uuid-1', type: 'question', title: 'Ask', question: 'What?', answer_type: 'text',
            transitions: [{ target_uuid: 'uuid-2' }] },
          { id: 'uuid-2', type: 'resolve', title: 'Done', resolution_type: 'success' }
        ]
      }.to_json

      file = Rack::Test::UploadedFile.new(
        StringIO.new(json_data), 'application/json', false, original_filename: 'workflow.json'
      )

      assert_difference 'Workflow.count', 1 do
        post workflow_import_path, params: { file: file }
      end

      assert_response :redirect
      assert_match(/imported successfully/i, flash[:notice])
    end

    test 'create with incomplete steps redirects to health panel' do
      json_data = {
        title: 'Incomplete Flow',
        description: 'Has incomplete steps',
        graph_mode: true,
        start_node_uuid: 'uuid-1',
        steps: [
          { id: 'uuid-1', type: 'question', title: 'Ask', answer_type: 'text',
            transitions: [{ target_uuid: 'uuid-2' }] },
          { id: 'uuid-2', type: 'resolve', title: 'Done', resolution_type: 'success' }
        ]
      }.to_json

      file = Rack::Test::UploadedFile.new(
        StringIO.new(json_data), 'application/json', false, original_filename: 'incomplete.json'
      )

      assert_difference 'Workflow.count', 1 do
        post workflow_import_path, params: { file: file }
      end

      workflow = Workflow.last
      assert_redirected_to edit_workflow_path(workflow, health: true)
      assert_match(/Review issues in the Health panel/i, flash[:notice])
    end

    test 'create requires authentication' do
      sign_out @editor
      post workflow_import_path

      assert_redirected_to new_user_session_path
    end
  end
end
