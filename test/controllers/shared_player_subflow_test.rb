require "test_helper"

# Anonymous runs from a share link, crossing a sub-flow.
#
# process_subflow_step creates the child scenario without shared_access, and
# PlayerController#set_scenario refuses an anonymous visitor any scenario where
# shared_access? is false. So a shared workflow with a sub-flow handed the
# visitor a 403 the moment the sub-flow opened.
class SharedPlayerSubflowTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(
      email: "share-owner-#{SecureRandom.hex(4)}@test.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )

    @child_wf = Workflow.create!(title: "Shared Child", user: @owner, status: "published")
    cq = Steps::Question.create!(
      workflow: @child_wf, title: "CQ", position: 0,
      variable_name: "cv", question: "Child question?"
    )
    cr = Steps::Resolve.create!(workflow: @child_wf, title: "CDone", position: 1, resolution_type: "success")
    Transition.create!(step: cq, target_step: cr, position: 0)
    @child_wf.update!(start_step: cq)
    @child_q = cq

    @workflow = Workflow.create!(title: "Shared Parent", user: @owner, status: "published")
    @sf = Steps::SubFlow.create!(
      workflow: @workflow, title: "SF", position: 0, sub_flow_workflow_id: @child_wf.id
    )
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: @sf, target_step: done, position: 0)
    @workflow.update!(start_step: @sf)
    @workflow.update!(share_token: SecureRandom.hex(8))
  end

  test "an anonymous visitor can enter a sub-flow from a share link" do
    get shared_player_path(@workflow.share_token)

    follow_redirect!

    assert_response :success, "an anonymous run must not be locked out of its own sub-flow"
  end

  test "a child scenario inherits shared access from its parent" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @owner, purpose: "live", shared_access: true,
      started_at: Time.current, current_node_uuid: @sf.uuid,
      execution_path: [], results: {}, inputs: {}
    )

    child = ScenarioSettler.new(scenario).settle_from_start

    assert_not_equal scenario.id, child.id, "precondition: we descended into the child"
    assert_predicate child, :shared_access?
  end
  # Retention is tiered by purpose: simulations are reaped after 7 days, live
  # runs after 90. A child created without a purpose takes the column default,
  # so a live run's sub-flow was deleted 83 days before the run it belongs to —
  # taking the answers the agent recorded inside it.
  test "a child scenario inherits its parent's purpose" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @owner, purpose: "live",
      started_at: Time.current, current_node_uuid: @sf.uuid,
      execution_path: [], results: {}, inputs: {}
    )

    child = ScenarioSettler.new(scenario).settle_from_start

    assert_equal "live", child.purpose
  end

  test "a live run's sub-flow survives the simulation retention window" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @owner, purpose: "live",
      started_at: Time.current, current_node_uuid: @sf.uuid,
      execution_path: [], results: {}, inputs: {}
    )
    child = ScenarioSettler.new(scenario).settle_from_start
    child.update!(status: "completed", completed_at: 30.days.ago)
    scenario.reload.update!(status: "completed", completed_at: 30.days.ago)

    Scenario.cleanup_stale

    assert Scenario.exists?(child.id),
           "the parent is a 90-day live run; its sub-flow must not vanish at 7 days"
  end
  # Embed mode sets a body class that strips the Player's chrome for an iframe.
  # It was computed in show_shared, which redirects — so the flag was set on a
  # request that renders nothing, and the page the visitor actually lands on
  # never saw it.
  test "an embedded shared run keeps embed mode through the redirect" do
    @workflow.update!(share_token: SecureRandom.hex(8), embed_enabled: true)

    get shared_player_path(@workflow.share_token, embed: "1")
    follow_redirect!

    assert_response :success
    assert_select "body.player-layout--embed", 1,
                  "the chrome-free layout must survive the hop to the step page"
  end

  test "embed mode is refused for a workflow that has not enabled it" do
    @workflow.update!(share_token: SecureRandom.hex(8), embed_enabled: false)

    get shared_player_path(@workflow.share_token, embed: "1")
    follow_redirect!

    assert_select "body.player-layout--embed", 0,
                  "asking for embed is not the same as being allowed it"
  end
end
