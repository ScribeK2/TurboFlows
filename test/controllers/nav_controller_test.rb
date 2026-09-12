require "test_helper"

class NavControllerTest < ActionDispatch::IntegrationTest
  fixtures :users, :workflows

  def setup
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @regular = users(:regular_user)
  end

  # --- the top bar ---
  #
  # Every destination is a labelled link in the bar. It used to be one create
  # action plus five admin destinations behind a 1.4rem chevron beside the
  # wordmark, and /admin itself was reachable from nowhere in the header.

  test "the chevron menu route is gone" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/nav/menu")
    end
    assert_not respond_to?(:nav_menu_path), "nav_menu_path should no longer exist"
  end

  test "nothing renders a menu trigger" do
    sign_in @admin
    get root_path
    assert_select ".nav__menu-trigger", count: 0
    assert_select "[data-controller='nav-menu']", count: 0
    assert_select "[data-controller='dialog-manager']", count: 0
  end

  test "admin bar carries Workflows, Play and Admin" do
    sign_in @admin
    get root_path
    assert_select "nav a.nav__link[href=?]", workflows_path, text: "Workflows"
    assert_select "nav a.nav__link[href=?]", play_path, text: "Play"
    assert_select "nav a.nav__link[href=?]", admin_root_path, text: "Admin"
  end

  test "editor bar carries Workflows and Play but not Admin" do
    sign_in @editor
    get root_path
    assert_select "nav a.nav__link[href=?]", workflows_path, text: "Workflows"
    assert_select "nav a.nav__link[href=?]", play_path, text: "Play"
    assert_select "nav a.nav__link[href=?]", admin_root_path, count: 0
  end

  test "regular bar carries Play only" do
    sign_in @regular
    get root_path
    assert_select "nav a.nav__link[href=?]", play_path, text: "Play"
    assert_select "nav a.nav__link[href=?]", workflows_path, count: 0
    assert_select "nav a.nav__link[href=?]", admin_root_path, count: 0
  end

  # Admin sits last so it can appear and disappear with the role without
  # reshuffling the positions above it — an editor and an admin see the same
  # first two destinations. Analytics sits directly before Admin (spec
  # 2026-09-12): an administrator is always allowed into Analytics too.
  test "Admin is the last destination" do
    sign_in @admin
    get root_path
    labels = css_select("nav .nav__links a.nav__link").map { |a| a.text.strip }
    assert_equal %w[Workflows Play Analytics Admin], labels
  end

  # --- you are here ---

  test "the brand marks the dashboard as current" do
    sign_in @admin
    get root_path
    assert_select "nav a.nav__brand-link[aria-current='page']"
  end

  test "Workflows is current on the workflows index" do
    sign_in @editor
    get workflows_path
    assert_select "nav a.nav__link[href=?][aria-current='page']", workflows_path
    assert_select "nav a.nav__link[href=?][aria-current='page']", play_path, count: 0
  end

  # /play is a browse page, so it renders the app shell and Play is current
  # there. It used to render the standalone player shell — `layout "player"` was
  # class-level and swept the index in with the run screens — which made the
  # section map's :play entry unreachable and left a regular user, whose only
  # other destination is the dashboard, with no top bar on the page they work on.
  # The old `controller_name == "player"` condition was dead for the same reason.
  test "Play is current on the player index" do
    sign_in @regular
    get play_path
    assert_response :success
    assert_select "nav.page-header"
    assert_select "nav a.nav__link[href=?][aria-current='page']", play_path
  end

  # The chrome still falls away when a run starts — that is the point of the
  # split. Entering a run is a mode change; opening the list is not.
  test "a run renders the player shell, not the app top bar" do
    workflow = Workflow.create!(title: "Shell Split #{SecureRandom.hex(3)}",
                                user: @regular, status: "published")
    question = Steps::Question.create!(workflow: workflow, position: 0, title: "Still running?",
                                       question: "Still running?", variable_name: "sr")
    resolve = Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done",
                                     resolution_type: "success")
    Transition.create!(step: question, target_step: resolve, position: 0)
    workflow.update!(start_step: question)

    scenario = Scenario.create!(workflow: workflow, user: @regular, purpose: "live",
                                started_at: Time.current, current_node_uuid: question.uuid,
                                execution_path: [], results: {}, inputs: {})

    sign_in @regular
    get player_scenario_step_path(scenario)
    assert_response :success
    assert_select "nav.page-header", count: 0
    assert_select "header.player-header"
  end

  test "Admin is current across admin pages, not just the hub" do
    sign_in @admin
    [admin_root_path, admin_users_path, admin_groups_path, admin_data_health_path].each do |path|
      get path
      assert_select "nav a.nav__link[href='#{admin_root_path}'][aria-current='page']", 1,
                    "#{path} should mark Admin as current"
      assert_select "nav a.nav__brand-link[aria-current='page']", count: 0
    end
  end

  test "exactly one destination is current at a time" do
    sign_in @admin
    get workflows_path
    assert_select "nav [aria-current='page']", count: 1
  end

  # --- search_data action ---

  test "search_data requires authentication" do
    get nav_search_data_path(format: :json)
    assert_response :unauthorized
  end

  test "search_data returns JSON array of workflows" do
    sign_in @admin
    Workflow.create!(title: "Test Flow", user: @admin, status: "draft")
    Workflow.create!(title: "Draft Flow", user: @admin, status: "draft")

    get nav_search_data_path(format: :json)
    assert_response :success

    data = response.parsed_body
    assert_kind_of Array, data
    assert_operator data.length, :>=, 2, "Expected at least 2 workflows"

    first = data.first
    assert first.key?("id")
    assert first.key?("title")
    assert first.key?("description")
    assert first.key?("status")
    assert first.key?("path")
  end

  test "search_data scopes workflows to user access" do
    other_user = users(:one)
    file_in_global(Workflow.create!(title: "Public Flow", user: other_user, status: "published"))
    Workflow.create!(title: "Private Flow", user: other_user, status: "draft")
    Workflow.create!(title: "My Flow", user: @regular, status: "draft")

    sign_in @regular
    get nav_search_data_path(format: :json)

    data = response.parsed_body
    titles = data.pluck("title")
    assert_includes titles, "Public Flow"
    assert_includes titles, "My Flow"
    assert_not_includes titles, "Private Flow"
  end

  # A regular user cannot open the builder or the execution landing page, so
  # every search result used to resolve to the bare Player index: twelve
  # workflows, one destination, and no sign the app had heard which one you
  # picked. Confirmed live during the role pass —
  # {"count": 12, "distinctPaths": ["/play"]}.
  test "a regular user's search results name the workflow they picked" do
    regular = User.create!(email: "nav-reg-#{SecureRandom.hex(4)}@example.com",
                           password: "password123!", password_confirmation: "password123!")
    group = Group.create!(name: "Nav Group #{SecureRandom.hex(3)}")
    regular.user_groups.create!(group: group)
    owner = User.create!(email: "nav-own-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    a = Workflow.create!(title: "Alpha Flow #{SecureRandom.hex(3)}", user: owner, status: "published")
    b = Workflow.create!(title: "Beta Flow #{SecureRandom.hex(3)}", user: owner, status: "published")
    [a, b].each { |w| w.groups << group }

    sign_in regular
    get nav_search_data_path, as: :json

    assert_response :success
    rows = response.parsed_body.select { |r| [a.title, b.title].include?(r["title"]) }

    assert_equal 2, rows.size, "precondition: both workflows are visible to this user"
    assert_equal 2, rows.pluck("path").uniq.size,
                 "two different workflows must not resolve to one destination"
    rows.each do |row|
      assert_includes row["path"], "/play"
      assert_includes CGI.unescape(row["path"]), row["title"],
                      "the result has to carry the workflow it names"
    end
  end
end
