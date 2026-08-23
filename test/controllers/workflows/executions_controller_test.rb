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
      @owner = @editor
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
    # Authorization matrix for starting a run. Moved here from
    # ScenariosControllerTest when scenarios#new/#create were deleted in
    # favour of this controller; without the move, deleting those routes
    # would have silently dropped every one of these cases.
    test "admin should be able to run scenario on any workflow" do
      admin = User.create!(
        email: "admin-sim-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "admin"
      )
      workflow = Workflow.create!(title: "Any Workflow", user: @owner, is_public: false)
      Steps::Question.create!(workflow: workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
      sign_in admin

      get new_workflow_execution_path(workflow)

      assert_response :success
    end

    test "editor should be able to run scenario on workflows they can view" do
      editor = User.create!(
        email: "editor-sim-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "editor"
      )
      own_workflow = Workflow.create!(title: "My Workflow", user: editor, is_public: false)
      Steps::Question.create!(workflow: own_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
      public_workflow = Workflow.create!(title: "Public Workflow", user: @owner, is_public: true)
      Steps::Question.create!(workflow: public_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
      sign_in editor

      get new_workflow_execution_path(own_workflow)

      assert_response :success

      get new_workflow_execution_path(public_workflow)

      assert_response :success
    end

    test "editor should not be able to run scenario on other user's private workflow" do
      editor = User.create!(
        email: "editor-sim2-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "editor"
      )
      private_workflow = Workflow.create!(title: "Private Workflow", user: @owner, is_public: false)
      Steps::Question.create!(workflow: private_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
      sign_in editor

      get new_workflow_execution_path(private_workflow)

      assert_redirected_to workflows_path
      assert_equal "You don't have permission to view this workflow.", flash[:alert]
    end

    test "user should be redirected to play from scenario on public workflow" do
      regular_user = User.create!(
        email: "user-sim-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "user"
      )
      public_workflow = Workflow.create!(title: "Public Workflow", user: @owner, is_public: true)
      Steps::Question.create!(workflow: public_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
      sign_in regular_user

      get new_workflow_execution_path(public_workflow)

      assert_redirected_to play_path
    end

    test "user should not be able to run scenario on private workflow" do
      regular_user = User.create!(
        email: "user-sim2-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "user"
      )
      private_workflow = Workflow.create!(title: "Private Workflow", user: @owner, is_public: false)
      Steps::Question.create!(workflow: private_workflow, position: 0, uuid: SecureRandom.uuid, title: "Question 1", question: "What is your name?")
      sign_in regular_user

      get new_workflow_execution_path(private_workflow)

      assert_redirected_to play_path
    end
  end
end
