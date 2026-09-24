require "test_helper"

# A step's guidance note and reference link, in both runners (2026-09-24).
# Guidance was grey text in a grey box, quieter than the step's own
# instructions; the link read "More info" in the card's smallest text. Now
# guidance is a labelled amber callout and the link is a button naming the
# site it opens.
class RunnerGuidanceTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "runner-guidance-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "admin")
    @workflow = Workflow.create!(title: "Guidance WF", user: @user, status: "draft")
    @question = Steps::Question.create!(
      workflow: @workflow, title: "Delete the domain?", question: "Domain or hosting only?", position: 0,
      answer_type: "yes_no", variable_name: "delete_domain",
      help_text: "Do not process the delete. Confirm the registration date in ICANN first.",
      reference_url: "https://www.lookup.icann.org/en/lookup"
    )
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: @question, target_step: done)
    @workflow.update!(start_step: @question)
    file_in_global(@workflow)
    WorkflowPublisher.publish(@workflow, @user)
    sign_in @user
  end

  # Mutation check: put the old grey .step-help-text markup back in
  # runner/_step_body - red.
  test "the player shows guidance as a labelled note and the link as a named button" do
    post play_workflow_path(@workflow)
    get player_scenario_step_path(Scenario.order(:id).last)

    assert_guidance_and_link
  end

  test "a scenario shows the same guidance note and link" do
    post workflow_execution_path(@workflow)
    get step_scenario_path(Scenario.order(:id).last)

    assert_guidance_and_link
  end

  test "a step with a link and no guidance still shows the link, and no empty note" do
    @question.update!(help_text: nil)
    post play_workflow_path(@workflow)
    get player_scenario_step_path(Scenario.order(:id).last)

    assert_select ".step-guidance", count: 0
    assert_select "a.step-reference-link", text: /lookup\.icann\.org/
  end

  # The Escalate card and the guidance note both used the warning triangle.
  # Escalate hands the call up a level, so it takes the builder's
  # arrow-up-circle; the triangle is guidance's alone.
  test "the escalate card's icon is not the guidance warning icon" do
    escalate = Steps::Escalate.create!(workflow: @workflow, title: "Hand to tier 2", position: 2)
    @workflow.update!(start_step: escalate)
    post workflow_execution_path(@workflow)
    get step_scenario_path(Scenario.order(:id).last)

    card_icon = css_select(".step-content-box--escalate .step-content-box__icon-wrap svg path").first["d"]
    assert_equal icon_path("arrow-up-circle"), card_icon
    assert_not_equal icon_path("exclamation-triangle"), card_icon
  end

  private

  def assert_guidance_and_link
    assert_response :success
    assert_select ".step-guidance[role=note][aria-labelledby]" do
      assert_select ".step-guidance__label", text: "Guidance"
      assert_select ".step-guidance__text", text: /Do not process the delete/
    end
    assert_select "a.step-reference-link[href=?][target=_blank][rel~=noopener]", "https://www.lookup.icann.org/en/lookup" do
      assert_select ".step-reference-link__label", text: "lookup.icann.org"
      assert_select ".sr-only", text: /opens in a new tab/
    end
    assert_no_match "More info", response.body
  end

  def icon_path(name)
    Nokogiri::HTML.fragment(ApplicationController.helpers.icon(name, class: "icon")).at_css("path")["d"]
  end
end
