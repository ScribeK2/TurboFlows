require "test_helper"

# Regression: 263717c8 (2026-04-07) closed /workflows and /scenarios to Regular
# users, and the CSR dashboard went on linking to both until 2026-09-13: every
# workflow title, Manage pins, View all and each Recent Activity row sent a CSR
# to /play with a permission error. Its tests asserted markup and never followed
# a link. This one follows every link the page renders, as the person it is for.
class CsrHomeLinksTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "csr-links-editor-#{SecureRandom.hex(4)}@example.com",
                           password: "password123!", password_confirmation: "password123!", role: "editor")
    @csr = User.create!(email: "csr-links-#{SecureRandom.hex(4)}@example.com",
                        password: "password123!", password_confirmation: "password123!")
    # In a group, so the page renders without the group notice or the /welcome redirect.
    UserGroup.create!(user: @csr, group: Group.create!(name: "Support #{SecureRandom.hex(3)}"))
    @billing = runnable_workflow("Billing Triage")
    @password = runnable_workflow("Password Reset")
    sign_in @csr
  end

  test "every link on the CSR home opens for a Regular user, and every form has a route" do
    UserWorkflowPin.create!(user: @csr, workflow: @billing)
    live_frame(@billing, status: "completed", outcome: "resolved")
    live_frame(@password, status: "active")

    get root_path
    assert_response :success

    links = css_select(".dashboard-layout a[href]").map { it["href"] }.uniq # rubocop:disable Rails/Pluck -- Nokogiri nodes, not an AR relation
    forms = css_select(".dashboard-layout form[action]").map do |form|
      [form["action"], (form.at_css("input[name='_method']")&.[]("value") || form["method"]).downcase.to_sym]
    end.uniq

    assert_includes links, player_scenario_step_path(Scenario.find_by!(workflow: @password)), "the Resume link is followed too"
    assert_not_empty forms

    links.each do |href|
      get href
      assert_response :success, "#{href} does not open for a Regular user"
    end
    # Not submitted: POST /play/:id starts a live call and the pin forms write.
    forms.each do |action, method|
      assert_nothing_raised do
        Rails.application.routes.recognize_path(action, method:)
      end
    end
  end

  test "Resume inside a live sub-flow opens the sub-flow's step" do
    parent = live_frame(@billing, status: "awaiting_subflow")
    Scenario.where(id: parent.id).update_all(updated_at: 3.hours.ago)
    child = live_frame(@password, status: "active", parent:)

    get root_path
    assert_select "#csr-resume a[href=?]", player_scenario_step_path(child), text: "Resume"

    get player_scenario_step_path(child)
    assert_response :success
  end

  test "Resume after a sub-flow finished opens the parked parent, which offers to continue" do
    parent = live_frame(@billing, status: "awaiting_subflow")
    Scenario.where(id: parent.id).update_all(updated_at: 3.hours.ago)
    live_frame(@password, status: "completed", outcome: "resolved", parent:)

    get root_path
    assert_select "#csr-resume a[href=?]", player_scenario_step_path(parent), text: "Resume"

    get player_scenario_step_path(parent)
    assert_response :success
  end

  test "Resume after a handoff opens the workflow the call moved to" do
    origin = live_frame(@billing, status: "completed", outcome: "transferred")
    handed_to = live_frame(@password, status: "active", handed_off_from: origin)

    get root_path
    assert_select "#csr-resume a[href=?]", player_scenario_step_path(handed_to), text: "Resume"
    assert_select "#csr-resume .list-row__sub", text: /Billing Triage/

    get player_scenario_step_path(handed_to)
    assert_response :success
  end

  private

  # Published, in Global, with a question to stand on, so a run on it is not
  # "complete" for want of steps.
  def runnable_workflow(title)
    workflow = file_in_global(Workflow.create!(title:, user: @editor))
    question = Steps::Question.create!(workflow:, title: "Verify account", position: 0,
                                       question: "Is the account verified?", answer_type: "yes_no")
    resolve = Steps::Resolve.create!(workflow:, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: question, target_step: resolve, position: 0)
    workflow.update!(start_step: question)
    workflow
  end

  def live_frame(workflow, status:, outcome: nil, parent: nil, handed_off_from: nil)
    terminal = Scenario::TERMINAL_STATUSES.include?(status)
    Scenario.create!(workflow:, user: @csr, purpose: "live", status:, outcome:,
                     parent_scenario: parent, handed_off_from:,
                     current_node_uuid: (workflow.start_step.uuid unless terminal),
                     started_at: 10.minutes.ago, completed_at: (Time.current if terminal),
                     execution_path: [], results: {}, inputs: {})
  end
end
