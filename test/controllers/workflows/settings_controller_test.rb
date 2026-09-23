# frozen_string_literal: true

require 'test_helper'

module Workflows
  class SettingsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @editor = User.create!(
        email: "settings-editor-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'editor'
      )
      @workflow = Workflow.create!(title: 'Settings Flow', user: @editor)
      sign_in @editor
    end

    test 'show renders settings panel partial' do
      get workflow_settings_path(@workflow)

      assert_response :success
    end

    # A share link opens only a PUBLISHED workflow (PlayerController#show_shared
    # uses Workflow.published), so on a draft it 404s - and the panel handed the
    # author a link to copy and send without a word (QA C-006, 2026-09-23).
    test 'a draft says its share link works only once it is published' do
      @workflow.update!(status: 'draft')
      get workflow_settings_path(@workflow)
      assert_select '.form-hint', text: /works once this workflow is published/

      @workflow.update!(share_token: SecureRandom.urlsafe_base64(16))
      get workflow_settings_path(@workflow)
      assert_select '.form-hint', text: /works once this workflow is published/
    end

    test 'a published workflow does not warn about its share link' do
      @workflow.update!(status: 'published', share_token: SecureRandom.urlsafe_base64(16))
      get workflow_settings_path(@workflow)
      assert_select '.form-hint', text: /works once this workflow is published/, count: 0
    end

    test 'show requires authentication' do
      sign_out @editor
      get workflow_settings_path(@workflow)

      assert_redirected_to new_user_session_path
    end

    test 'show redirects regular users to player' do
      regular_user = User.create!(
        email: "settings-regular-#{SecureRandom.hex(4)}@example.com",
        password: 'password123!',
        password_confirmation: 'password123!',
        role: 'user'
      )
      sign_in regular_user
      get workflow_settings_path(@workflow)

      assert_redirected_to play_path
    end

    test "Details is a preview when the builder is in view mode" do
      get workflow_settings_path(@workflow, readonly: 1)

      assert_response :success
      assert_select "form", count: 0
      assert_select "turbo-frame#builder-panel", text: /Who Can See This/
    end
  end
end
