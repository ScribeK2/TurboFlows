# frozen_string_literal: true

require 'test_helper'

module Workflows
  class ExportsControllerTest < ActionDispatch::IntegrationTest
    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "editor-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'editor'
      )
      @workflow = Workflow.create!(title: 'Exportable Flow', user: @editor)
      Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: 'Done', resolution_type: 'success'
      )
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test 'show returns JSON export' do
      get workflow_export_path(@workflow)

      assert_response :success
      assert_match 'application/json', response.content_type
      json = response.parsed_body

      assert_equal 'Exportable Flow', json['title']
      assert_kind_of Array, json['steps']
      assert_equal '2.0', json['export_version']
    end

    test 'pdf returns PDF binary' do
      get pdf_workflow_export_path(@workflow)

      assert_response :success
      assert_match 'application/pdf', response.content_type
      assert response.body.start_with?('%PDF')
    end

    test 'show requires authentication' do
      sign_out @editor
      get workflow_export_path(@workflow)

      assert_redirected_to new_user_session_path
    end
  end
end
