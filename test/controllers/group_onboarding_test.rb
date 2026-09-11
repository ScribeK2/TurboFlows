require "test_helper"

# A person in no group is sent from the dashboard to a page where they choose
# their own (spec 2026-09-11 Q2, Q3, Q10, Q12).
class GroupOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    @tag = SecureRandom.hex(4)
    @user = person("regular")
    @support = Group.create!(name: "Onboard Support #{@tag}")
    @tier1 = Group.create!(name: "Tier 1", parent: @support, description: "First-line calls")
    @escalations = Group.create!(name: "Escalations", parent: @support, admins_add_members: true)
    @hr = Group.create!(name: "Onboard HR #{@tag}")
    sign_in @user
  end

  # -- The redirect --

  test "the dashboard sends a Regular user in no group to the welcome page" do
    get root_path

    assert_redirected_to welcome_path
  end

  test "an Editor in no group is sent too" do
    @user.update!(role: "editor")

    get root_path

    assert_redirected_to welcome_path
  end

  test "nobody is sent who is an admin, is in a group, or has nothing to join" do
    @user.update!(role: "admin")
    get root_path
    assert_response :success

    @user.update!(role: "regular")
    UserGroup.create!(user: @user, group: @hr)
    get root_path
    assert_response :success

    UserGroup.where(user: @user).delete_all
    Group.where(parent_id: nil).update_all(admins_add_members: true)
    get root_path
    assert_response :success
  end

  test "only the dashboard redirects" do
    get play_path

    assert_response :success
  end

  # -- The page --

  test "the page offers joinable groups with descriptions, and hides the rest" do
    global_group

    get welcome_path

    assert_response :success
    offered = css_select(".group-picker__option").pluck("data-path").select { |path| path.include?(@tag.downcase) }
    assert_equal ["onboard hr #{@tag}", "onboard support #{@tag} / tier 1"].sort, offered.sort
    assert_select ".group-picker__global", 0
    assert_select ".group-picker__option[data-path=?] .group-picker__note", "onboard support #{@tag} / tier 1", text: "First-line calls"
    assert_select ".form-hint", text: "Can't find your team? An administrator can add you."
    assert_select ".btn--primary", 1
  end

  # The description sits inside the label for layout. Hidden from the label's
  # text and pointed at by aria-describedby, it is read after the name instead
  # of as part of it.
  test "a group's description is announced as its checkbox's description, not its name" do
    get welcome_path

    path = "onboard support #{@tag} / tier 1"
    note = css_select(".group-picker__option[data-path='#{path}'] .group-picker__note").first
    assert_equal "true", note["aria-hidden"]
    assert_predicate note["id"], :present?
    assert_select ".group-picker__option[data-path=?] input[aria-describedby=?]", path, note["id"].to_s
  end

  test "someone who has nothing to be welcomed to goes back to the dashboard" do
    UserGroup.create!(user: @user, group: @hr)

    get welcome_path

    assert_redirected_to root_path
  end

  # -- Joining --

  test "joining takes effect at once and lands on the dashboard naming the groups" do
    post welcome_path, params: { group_ids: [@tier1.id, @hr.id] }

    assert_redirected_to root_path
    assert_equal "You're in Onboard HR #{@tag} and Onboard Support #{@tag} / Tier 1.", flash[:notice]
    assert_equal [@tier1.id, @hr.id].sort, @user.user_groups.where(self_joined: true).pluck(:group_id).sort
    follow_redirect!
    assert_response :success
  end

  test "joining nothing asks for a group" do
    post welcome_path, params: { group_ids: [""] }

    assert_redirected_to welcome_path
    assert_equal "Choose at least one group, or skip for now.", flash[:alert]
  end

  test "nothing chosen, posted as no field at all, asks for a group" do
    post welcome_path

    assert_redirected_to welcome_path
    assert_equal "Choose at least one group, or skip for now.", flash[:alert]
  end

  # A form sends group_ids[] as a list. Anything else came from a hand-built
  # request, and reads as nothing chosen rather than an error page.
  test "group ids posted in the wrong shape join nothing and ask for a group" do
    post welcome_path, params: { group_ids: { a: @hr.id } }

    assert_redirected_to welcome_path
    assert_equal "Choose at least one group, or skip for now.", flash[:alert]
    assert_empty @user.user_groups.reload
  end

  test "a group posted twice is joined once and named once" do
    post welcome_path, params: { group_ids: [@hr.id, @hr.id] }

    assert_equal "You're in Onboard HR #{@tag}.", flash[:notice]
    assert_equal [@hr.id], @user.user_groups.reload.map(&:group_id)
  end

  test "joining reads the group tree once" do
    tree_reads = count_self_joinable_reads { post welcome_path, params: { group_ids: [@hr.id] } }

    assert_equal 1, tree_reads
  end

  test "a posted group nobody offered is refused and joins nothing" do
    post welcome_path, params: { group_ids: [@hr.id, @escalations.id] }

    assert_redirected_to welcome_path
    assert_equal "An administrator adds people to that group.", flash[:alert]
    assert_empty @user.user_groups.reload
  end

  # -- Skip --

  test "the welcome page still opens after Skip, so the notice's link works" do
    post welcome_skip_path

    get welcome_path

    assert_response :success
  end

  test "Skip holds for the session and the next session offers the page again" do
    post welcome_skip_path

    assert_redirected_to root_path
    get root_path
    assert_response :success

    delete destroy_user_session_path
    sign_in @user
    get root_path

    assert_redirected_to welcome_path
  end

  # -- The dashboard notice --

  test "someone who skipped sees why the dashboard is sparse and a way back" do
    post welcome_skip_path
    get root_path

    assert_select "section[aria-label='Your groups'] a[href=?]", welcome_path, text: "Choose your groups"
  end

  test "with nothing to join the notice names who will act" do
    Group.where(parent_id: nil).update_all(admins_add_members: true)

    get root_path

    assert_select "section[aria-label='Your groups']", text: /An administrator will add you to a group\./
    assert_select "section[aria-label='Your groups'] a[href=?]", welcome_path, count: 0
  end

  test "an Editor's notice counts the workflows they made" do
    @user.update!(role: "editor")
    post welcome_skip_path

    get root_path

    assert_select "section[aria-label='Your groups'] .list-row__sub", text: /the workflows everyone can see and the ones you made\./
  end

  test "the dashboard asks whether someone is in a group once" do
    post welcome_skip_path
    membership_checks = 0
    counter = ->(*, payload) { membership_checks += 1 if payload[:sql].start_with?('SELECT 1 AS one FROM "user_groups"') }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }

    assert_response :success
    assert_equal 1, membership_checks
  end

  test "nobody in a group sees the notice" do
    UserGroup.create!(user: @user, group: @hr)

    get root_path

    assert_select "section[aria-label='Your groups']", 0
  end

  private

  # Group.self_joinable_ids is the one query that plucks admins_add_members.
  def count_self_joinable_reads(&)
    reads = 0
    counter = ->(*, payload) { reads += 1 if payload[:sql].include?("admins_add_members") && payload[:sql].start_with?("SELECT") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    reads
  end

  def person(role)
    User.create!(email: "onboard-#{role}-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role)
  end
end
