require "test_helper"

# Who a share-link run belongs to.
#
# PlayerController#show_shared stamped `user: @workflow.user`, so a stranger
# following a share link produced a run recorded as the OWNER's. That is not a
# cosmetic wrong: AnalyticsController#build_agent_stats groups runs by
# users.email, so an editor who shared one workflow widely appeared to be the
# busiest agent in the organisation.
#
# `scenarios.user_id` is now nullable. NULL says what is true — nobody we can
# name ran this — rather than naming the wrong person. A sentinel "Anonymous"
# user was rejected: it keeps the constraint at the cost of a fake account in the
# admin user list and the agent filter, and every reader still has to know it is
# special.
class SharedRunAttributionTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(
      email: "owner-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @visitor = User.create!(
      email: "visitor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Shared #{SecureRandom.hex(3)}", user: @owner,
                                 graph_mode: true)
    question = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1",
                                       question: "What?", variable_name: "q1")
    resolve = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done",
                                     resolution_type: "success")
    Transition.create!(step: question, target_step: resolve, position: 0)
    @workflow.update!(start_step: question)
    WorkflowPublisher.publish(@workflow, @owner)
    @workflow.reload.generate_share_token! if @workflow.respond_to?(:generate_share_token!)
    @workflow.update!(share_token: SecureRandom.hex(16)) if @workflow.share_token.blank?
  end

  # --- who the run belongs to -------------------------------------------------

  test "an anonymous share-link run belongs to nobody" do
    assert_difference "Scenario.count", 1 do
      get shared_player_path(@workflow.share_token)
    end

    scenario = Scenario.order(:id).last
    assert_nil scenario.user_id, "the visitor was never identified; naming the owner is a lie"
    assert scenario.shared_access, "it is still marked as having come through a share link"
    assert_not_equal @owner.id, scenario.user_id
  end

  test "a signed-in visitor following a share link is recorded as themselves" do
    sign_in @visitor

    get shared_player_path(@workflow.share_token)

    scenario = Scenario.order(:id).last
    assert_equal @visitor.id, scenario.user_id,
                 "a signed-in visitor is a real agent and their run is theirs"
    assert_not_equal @owner.id, scenario.user_id
  end

  test "an owner running their own share link is recorded as themselves, not by accident" do
    sign_in @owner

    get shared_player_path(@workflow.share_token)

    assert_equal @owner.id, Scenario.order(:id).last.user_id
  end

  # --- the consumer that made this matter -------------------------------------

  test "anonymous runs do not inflate the owner's per-agent figures" do
    admin = User.create!(
      email: "admin-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "admin"
    )
    3.times { get shared_player_path(@workflow.share_token) }
    Scenario.where(user_id: nil).update_all(outcome: "completed", status: "completed",
                                            completed_at: Time.current)
    sign_in admin

    # 90d, explicitly: raw mode, where per-agent stats exist at all.
    get analytics_path(range: "90d")

    assert_response :success
    assert_no_match(/#{Regexp.escape(@owner.email)}/, response.body,
                    "the owner ran nothing; joins(:user) drops the anonymous runs on its own")
  end

  # --- the run still works ----------------------------------------------------

  test "an anonymous run can still be played through to its end" do
    get shared_player_path(@workflow.share_token)
    scenario = Scenario.order(:id).last

    follow_redirect!
    assert_response :success

    post player_scenario_next_path(scenario), params: { answer: "yes" },
                                              headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_nil scenario.reload.user_id, "playing it must not quietly attach a user"
  end

  test "a sub-flow spawned inside an anonymous run is also anonymous" do
    get shared_player_path(@workflow.share_token)
    parent = Scenario.order(:id).last

    child = Scenario.create!(workflow: @workflow, user: parent.user, purpose: "live",
                             status: "active", parent_scenario: parent,
                             started_at: Time.current, execution_path: [], results: {},
                             inputs: {})

    assert_nil child.user_id, "the child of an anonymous run has no more of a user than its parent"
  end
end
