# frozen_string_literal: true

require 'test_helper'

module Workflows
  class VariablesControllerTest < ActionDispatch::IntegrationTest
    def setup
      @editor = User.create!(
        email: "vars-editor-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'editor'
      )
      @workflow = Workflow.create!(title: 'Variables Flow', user: @editor, is_public: true)
      sign_in @editor
    end

    test 'show returns JSON with variables' do
      get workflow_variables_path(@workflow), as: :json

      assert_response :success
      body = response.parsed_body

      assert body.key?('variables')
    end

    test 'show includes variable names from question steps' do
      Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: 'Name?', question: 'What is your name?',
        answer_type: 'text', variable_name: 'customer_name'
      )
      get workflow_variables_path(@workflow), as: :json

      assert_response :success
      body = response.parsed_body

      assert_includes body['variables'], 'customer_name'
    end

    test 'show requires authentication' do
      sign_out @editor
      get workflow_variables_path(@workflow), as: :json

      assert_response :unauthorized
    end

    test 'show redirects regular users to player' do
      regular_user = User.create!(
        email: "vars-regular-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'user'
      )
      sign_in regular_user
      get workflow_variables_path(@workflow), as: :json

      assert_redirected_to play_path
    end
  end
end
