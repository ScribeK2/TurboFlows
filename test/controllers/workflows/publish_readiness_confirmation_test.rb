# frozen_string_literal: true

require "test_helper"

module Workflows
  # Readiness never refuses a publish (grill Q11) — a hard block gets worked
  # around by typing a space into the field. It interrupts once and asks.
  #
  # This is the half of the fix the first-time editor needed: he shipped a
  # two-step workflow he knew was inadequate, and the product congratulated him.
  # An acknowledgement makes that a decision rather than a green light.
  class PublishReadinessConfirmationTest < ActionDispatch::IntegrationTest
    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "ready-#{SecureRandom.hex(4)}@example.com",
        password: "password123!", password_confirmation: "password123!", role: "editor"
      )
      @workflow = file_in_global(Workflow.create!(title: "Thin Flow", user: @editor))
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test "publishing a workflow that is not ready asks first and writes nothing" do
      build_thin_workflow

      assert_no_difference "WorkflowVersion.count" do
        post workflow_publishing_path(@workflow)
      end

      assert_redirected_to confirm_workflow_publishing_path(@workflow)
      # published_version_id, not status: the status enum defaults to "published"
      # on create, so it says nothing about whether a publish happened.
      assert_nil @workflow.reload.published_version_id
    end

    test "the confirmation names what is not ready" do
      build_thin_workflow

      get confirm_workflow_publishing_path(@workflow)

      assert_response :success
      assert_match(/no message/i, response.body)
    end

    test "acknowledging publishes it" do
      build_thin_workflow

      assert_difference "WorkflowVersion.count", 1 do
        post workflow_publishing_path(@workflow), params: { acknowledge_readiness: "1" }
      end

      assert_redirected_to workflow_path(@workflow)
      assert_not_nil @workflow.reload.published_version_id
    end

    test "a fully written workflow publishes without being asked" do
      build_thin_workflow
      @message.content = "<p>Walk them through the reset.</p>"
      @message.save!

      assert_difference "WorkflowVersion.count", 1 do
        post workflow_publishing_path(@workflow)
      end

      assert_redirected_to workflow_path(@workflow)
    end

    # The confirmation is for readiness and for multi-workflow sets. Landing on
    # it with neither should not strand anyone on a page with nothing to confirm.
    test "the confirmation redirects away when there is nothing to confirm" do
      build_thin_workflow
      @message.content = "<p>Walk them through the reset.</p>"
      @message.save!

      get confirm_workflow_publishing_path(@workflow)

      assert_redirected_to workflow_path(@workflow)
    end

    # Readiness must not smuggle in a refusal: a genuinely invalid graph still
    # fails on its own terms, not via the confirmation.
    test "an invalid graph still fails rather than asking" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      @workflow.update!(start_step: q)

      assert_no_difference "WorkflowVersion.count" do
        post workflow_publishing_path(@workflow), params: { acknowledge_readiness: "1" }
      end

      assert_match(/failed to publish/i, flash[:alert].to_s)
    end

    # The case above passed for the wrong reason — its workflow happened to have
    # no readiness issues, so the gate was never reached. A workflow that is BOTH
    # unpublishable and thin must hear about the thing that stops it, not about
    # its empty message bodies: the confirmation page says nothing about a broken
    # graph, so asking first sends the author to click "Publish anyway" and only
    # then meet the real refusal.
    test "a workflow that is both broken and thin reports the breakage, not the thinness" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0, title: "Which error?"
      )
      @workflow.update!(start_step: q)

      assert_not_empty WorkflowHealthCheck.call(@workflow.reload).readiness_issues,
                       "fixture must be thin for this test to mean anything"

      assert_no_difference "WorkflowVersion.count" do
        post workflow_publishing_path(@workflow)
      end

      assert_match(/failed to publish/i, flash[:alert].to_s)
    end

    private

    def build_thin_workflow
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Which error?", question: "Read it out.", answer_type: "yes_no",
        options: [{ "label" => "Locked", "value" => "locked" }]
      )
      @message = Steps::Message.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1, title: "Talk them through it"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 2,
        title: "Signed in", resolution_type: "success"
      )
      r.description = "<p>Confirm before ending the call.</p>"
      r.save!
      Transition.create!(step: q, target_step: @message, position: 0)
      Transition.create!(step: @message, target_step: r, position: 0)
      @workflow.update!(start_step: q)
      @workflow.reload
    end
  end
end
