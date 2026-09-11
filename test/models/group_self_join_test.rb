require "test_helper"

# Which groups a person may join or leave on their own (spec 2026-09-11 Q6).
# Membership covers subgroups, so the rule has to hold in both directions: joining
# the parent of a managed group would reach it, and a managed group's subgroups
# belong to it.
class GroupSelfJoinTest < ActiveSupport::TestCase
  setup do
    tag = SecureRandom.hex(3)
    @support = Group.create!(name: "Support #{tag}")
    @tier1 = Group.create!(name: "Tier 1", parent: @support)
    @tier2 = Group.create!(name: "Tier 2", parent: @support)
    @escalations = Group.create!(name: "Escalations", parent: @support)
    @night = Group.create!(name: "Night", parent: @escalations)
    @hr = Group.create!(name: "HR #{tag}")
    @payroll = Group.create!(name: "Payroll", parent: @hr)
  end

  test "every group is joinable until an administrator manages one" do
    ids = Group.self_joinable_ids

    [@support, @tier1, @tier2, @escalations, @night, @hr, @payroll].each { assert_includes ids, it.id }
  end

  test "Global is never joinable" do
    global = global_group

    assert_not_includes Group.self_joinable_ids, global.id
  end

  test "a managed group in the middle takes itself, everything above and everything below" do
    @escalations.update!(admins_add_members: true)

    ids = Group.self_joinable_ids

    assert_not_includes ids, @escalations.id
    assert_not_includes ids, @night.id, "a subgroup of a managed group belongs to it"
    assert_not_includes ids, @support.id, "joining the parent would reach the managed group"
    assert_includes ids, @tier1.id, "a sibling reaches nothing managed"
    assert_includes ids, @tier2.id
    assert_includes ids, @hr.id, "an unrelated tree is untouched"
  end

  test "a managed root takes its whole tree" do
    @hr.update!(admins_add_members: true)

    ids = Group.self_joinable_ids

    assert_not_includes ids, @hr.id
    assert_not_includes ids, @payroll.id
    assert_includes ids, @support.id
  end

  test "a managed leaf takes only itself and its ancestors" do
    @night.update!(admins_add_members: true)

    ids = Group.self_joinable_ids

    assert_not_includes ids, @night.id
    assert_not_includes ids, @escalations.id
    assert_not_includes ids, @support.id
    assert_includes ids, @tier1.id
  end

  # Walking up from a managed grandchild marks its parent before the root's own
  # walk down reaches it, when the grandchild is visited first. A walk down that
  # stopped at already-marked groups would then never reach that parent's other
  # children. Rows come back in id order, so the grandchild is created first and
  # moved into place to be visited before its root.
  test "a managed root with a managed grandchild still takes every group in between and beside" do
    grandchild = Group.create!(name: "Early #{SecureRandom.hex(3)}", admins_add_members: true)
    root = Group.create!(name: "Late Root #{SecureRandom.hex(3)}", admins_add_members: true)
    middle = Group.create!(name: "Middle", parent: root)
    beside = Group.create!(name: "Beside", parent: middle)
    grandchild.update!(parent: middle)

    ids = Group.self_joinable_ids

    [grandchild, root, middle, beside].each { assert_not_includes ids, it.id }
    assert_includes ids, @hr.id
  end

  test "descriptions_by_id returns only the groups given that have one" do
    @tier1.update!(description: "Password resets and first-line calls")
    @tier2.update!(description: "")

    descriptions = Group.descriptions_by_id([@tier1.id, @tier2.id, @hr.id])

    assert_equal({ @tier1.id => "Password resets and first-line calls" }, descriptions)
  end

  # Global's audience is everyone signed in, and nobody joins it, so the setting
  # would mean nothing while Global's page announced it.
  test "Global can't be kept to administrators" do
    global = global_group
    global.admins_add_members = true

    assert_not global.valid?
    assert_includes global.errors[:admins_add_members], "can't be set on Global, which everyone signed in already sees"
  end
end
