require "test_helper"

# Regression: ISSUE-003 — analytics counted every workflow a call passed through as a run
# Found by /qa on 2026-09-12
# Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
#
# Counting calls in SQL needs every frame to say which call it belongs to.
# `run_origin_id` is `run_origin` written down when a frame is created, from the
# only two links a new frame is born with. An origin leaves it NULL, so a frame's
# call is `COALESCE(run_origin_id, id)`.
class ScenarioRunOriginIdTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "origin-id-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @wf = Workflow.create!(title: "W #{SecureRandom.hex(3)}", user: @user)
  end

  def frame(parent: nil, handed_off_from: nil)
    Scenario.create!(workflow: @wf, user: @user, purpose: "live", status: "active",
                     parent_scenario: parent, handed_off_from: handed_off_from,
                     execution_path: [], results: {}, inputs: {})
  end

  test "an origin names no other frame" do
    assert_nil frame.run_origin_id
  end

  test "every frame of a mixed chain names the origin run_origin finds" do
    a = frame
    b = frame(parent: a)
    c = frame(handed_off_from: b)
    d = frame(parent: c)
    e = frame(handed_off_from: d)

    [b, c, d, e].each do |f|
      assert_equal a.id, f.run_origin_id, "S#{f.id}"
      assert_equal f.run_origin.id, f.run_origin_id, "the column and the walk must agree from S#{f.id}"
    end
  end

  test "the frame a run is handed off to carries it" do
    target = Workflow.create!(title: "Target #{SecureRandom.hex(3)}", user: @user)
    tq = Steps::Question.create!(workflow: target, position: 0, title: "Second", question: "Second?",
                                 variable_name: "second")
    tr = Steps::Resolve.create!(workflow: target, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: tq, target_step: tr, position: 0)
    target.update!(start_step: tq)

    q = Steps::Question.create!(workflow: @wf, position: 0, title: "First", question: "First?", variable_name: "first")
    handoff = Steps::SubFlow.create!(workflow: @wf, position: 1, title: "Hand off",
                                     sub_flow_workflow_id: target.id, sub_flow_returns: false)
    Transition.create!(step: q, target_step: handoff, position: 0)
    @wf.update!(start_step: q)
    run = Scenario.create!(workflow: @wf, user: @user, purpose: "live", status: "active", started_at: Time.current,
                           current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {})

    ScenarioSettler.new(run).settle("yes")

    assert_equal run.id, Scenario.find_by!(handed_off_from: run).run_origin_id
  end
end
