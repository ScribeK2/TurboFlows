# frozen_string_literal: true

require 'test_helper'

module Workflows
  class ExecutionsControllerTest < ActionDispatch::IntegrationTest
    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "editor-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'editor'
      )
      @workflow = Workflow.create!(title: 'Executable Flow', user: @editor)
      @step = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: 'Done', resolution_type: 'success'
      )
      @workflow.update!(start_step: @step)
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test 'new renders start page' do
      get new_workflow_execution_path(@workflow)

      assert_response :success
    end

    test 'create creates scenario and redirects' do
      assert_difference 'Scenario.count', 1 do
        post workflow_execution_path(@workflow)
      end

      scenario = Scenario.last

      assert_equal @workflow.id, scenario.workflow_id
      assert_equal @editor.id, scenario.user_id
      assert_redirected_to step_scenario_path(scenario)
    end

    test 'create requires authentication' do
      sign_out @editor
      post workflow_execution_path(@workflow)

      assert_redirected_to new_user_session_path
    end
  end
end
