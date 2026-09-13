require "application_system_test_case"

# The whole loop in a browser (spec 2026-09-13-group-featured-workflows): a
# manager features two workflows and reorders them, and a CSR on that team sees
# them first on home, in that order.
class TeamFeaturedWorkflowsTest < ApplicationSystemTestCase
  setup do
    tag = SecureRandom.hex(3)
    @team = Group.create!(name: "wf-system-test-group-#{tag}")
    @manager = person("manager-#{tag}")
    GroupManager.create!(group: @team, user: @manager)
    @csr = person("csr-#{tag}")
    UserGroup.create!(user: @csr, group: @team)
    author = User.create!(email: "wf-system-test-author-#{tag}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    @first = runnable("Alpha Kit #{tag}", author)
    @second = runnable("Beta Kit #{tag}", author)
  end

  teardown do
    Group.where("name LIKE ?", "wf-system-test-group-%").destroy_all
  end

  test "a manager features and reorders, and the CSR sees the team's kit first on home" do
    sign_in_as @manager
    visit team_path(@team)

    [@first, @second].each do |workflow|
      find("input[aria-label='Find workflows to feature for #{@team.name}']").set(workflow.title)
      find("button[aria-label='Feature #{workflow.title} for #{@team.name}']", wait: 5).click
      # Not `.admin-group__name`: a still-open search result for the same title
      # matches that just as well, before the Feature POST has even landed, so
      # the next iteration could start typing while this one is still in
      # flight and lose its own keystrokes to the delayed replace. Remove only
      # exists on a row that is actually featured.
      assert_selector "#team-featured button[aria-label='Remove #{workflow.title} from #{@team.name}']", wait: 5
    end

    find("button[aria-label='Move #{@second.title} up']").click
    assert_selector "#team-featured li:first-child .admin-group__name", text: @second.title, wait: 5

    Capybara.reset_sessions!
    sign_in_as @csr
    visit root_path

    within("#team-workflows-section") do
      assert_selector ".dashboard-team__heading", text: @team.name
      titles = all(".list-row__title").map(&:text)
      assert_equal [@second.title, @first.title], titles
    end
  end

  private

  def person(label)
    User.create!(email: "wf-system-test-#{label}@example.com", password: "password123!",
                 password_confirmation: "password123!")
  end

  def runnable(title, user)
    workflow = Workflow.create!(title:, user:, status: "published")
    step = Steps::Resolve.create!(workflow:, title: "Done", position: 0, resolution_type: "success")
    workflow.update!(start_step: step)
    GroupWorkflow.create!(group: @team, workflow:, is_primary: true)
    workflow
  end
end
