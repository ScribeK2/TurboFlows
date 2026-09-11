require "test_helper"

# My groups (spec 2026-09-11 Q8): join or leave any joinable group; a group the
# person could not rejoin is shown read-only.
class Profiles::MembershipsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tag = SecureRandom.hex(4)
    @user = User.create!(email: "mine-#{@tag}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "regular")
    @support = Group.create!(name: "Mine Support #{@tag}")
    @tier1 = Group.create!(name: "Tier 1", parent: @support)
    @escalations = Group.create!(name: "Escalations", parent: @support, admins_add_members: true)
    @hr = Group.create!(name: "Mine HR #{@tag}", description: "People matters")
    sign_in @user
  end

  test "the profile lists my groups, lets me leave joinable ones and shows the rest read-only" do
    UserGroup.create!(user: @user, group: @tier1)
    UserGroup.create!(user: @user, group: @escalations)

    get edit_profile_path

    assert_select "#my-groups .list-row", 2
    assert_select "#my-groups .list-row", text: %r{Mine Support #{@tag} / Tier 1} do
      assert_select "form[action=?]", profile_membership_path(UserGroup.find_by!(user: @user, group: @tier1))
    end
    assert_select "#my-groups .list-row", text: /Escalations/ do
      assert_select "form", 0
      assert_select ".list-row__sub", text: "Only an administrator can change this"
    end
  end

  test "the join picker offers only joinable groups I'm not in, with descriptions" do
    UserGroup.create!(user: @user, group: @tier1)

    get edit_profile_path

    offered = css_select("#my-groups .group-picker__option").pluck("data-path").select { |path| path.include?(@tag.downcase) }
    assert_equal ["mine hr #{@tag}"], offered
    assert_select "#my-groups .group-picker__note", text: "People matters"
    assert_select ".btn--primary", 1
  end

  # Membership covers subgroups, so joining one below a group you are in adds a
  # row that changes nothing you can see.
  test "the join picker leaves out subgroups I already see through a group I'm in" do
    sales = Group.create!(name: "Mine Sales #{@tag}")
    east = Group.create!(name: "East", parent: sales)
    Group.create!(name: "North", parent: east)
    UserGroup.create!(user: @user, group: sales)

    get edit_profile_path

    offered = css_select("#my-groups .group-picker__option").pluck("data-path")
    assert_not_includes offered, "mine sales #{@tag} / east"
    assert_not_includes offered, "mine sales #{@tag} / east / north"
    assert_includes offered, "mine hr #{@tag}", "a group outside the ones I'm in is still offered"
  end

  test "the profile reads the group tree once" do
    UserGroup.create!(user: @user, group: @tier1)
    tree_reads = 0
    counter = ->(*, payload) { tree_reads += 1 if payload[:sql].match?(/\ASELECT "groups"\."id", "groups"\."name", "groups"\."parent_id" FROM "groups"\z/) }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get edit_profile_path }

    assert_equal 1, tree_reads
  end

  test "an administrator's profile has no My groups" do
    @user.update!(role: "admin")

    get edit_profile_path

    assert_select "#my-groups", 0
  end

  test "joining from the profile marks the membership and returns to My groups" do
    post profile_memberships_path, params: { group_ids: [@hr.id] }

    assert_redirected_to edit_profile_path(anchor: "my-groups")
    assert_equal "You're in Mine HR #{@tag}.", flash[:notice]
    assert_predicate UserGroup.find_by!(user: @user, group: @hr), :self_joined?
  end

  test "joining nothing, or a group nobody offered, joins nothing" do
    post profile_memberships_path, params: { group_ids: [""] }
    assert_equal "Choose at least one group to join.", flash[:alert]

    post profile_memberships_path, params: { group_ids: [@escalations.id] }
    assert_equal "An administrator adds people to that group.", flash[:alert]

    post profile_memberships_path, params: { group_ids: { a: @hr.id } }
    assert_equal "Choose at least one group to join.", flash[:alert]

    assert_empty @user.user_groups.reload
  end

  test "leaving a joinable group removes it, whoever added me" do
    membership = UserGroup.create!(user: @user, group: @tier1)

    delete profile_membership_path(membership)

    assert_redirected_to edit_profile_path(anchor: "my-groups")
    assert_equal "You left Mine Support #{@tag} / Tier 1.", flash[:notice]
    assert_not UserGroup.exists?(membership.id)
  end

  test "a group I could not rejoin can't be left here" do
    membership = UserGroup.create!(user: @user, group: @escalations)

    delete profile_membership_path(membership)

    assert_equal "Only an administrator can take you out of that group.", flash[:alert]
    assert UserGroup.exists?(membership.id)
  end

  test "someone else's membership is not mine to leave" do
    other = User.create!(email: "mine-other-#{@tag}@example.com", password: "password123!",
                         password_confirmation: "password123!")
    membership = UserGroup.create!(user: other, group: @tier1)

    delete profile_membership_path(membership)

    assert_response :not_found
    assert UserGroup.exists?(membership.id)
  end
end
