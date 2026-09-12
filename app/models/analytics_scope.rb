# Whose runs a person may see in Analytics (spec 2026-09-12), decided in one
# place: the page, its filters, its CSV and the drill-down all ask here.
#
# An administrator sees every run. A manager sees runs by members of the groups
# they manage and of those groups' sub-teams, read at request time, so a CSR who
# moves teams takes their history with them. Everyone else sees none.
#
# Scoped by who ran it, not by the workflow: a sub-flow or handoff frame carries
# the agent of the call it belongs to, so a call stays whole, and a manager sees
# their team's runs on workflows they cannot open themselves.
class AnalyticsScope
  def initialize(user)
    @user = user
  end

  def allowed?
    everyone? || managed_group_ids.any?
  end

  def everyone?
    @user&.admin? || false
  end

  # Rollups hold daily totals per workflow, with no agent to limit them by.
  def all_time?
    everyone?
  end

  def scenarios
    return Scenario.all if everyone?
    return Scenario.none if managed_group_ids.empty?

    Scenario.where(user_id: team_member_ids)
  end

  def includes_agent?(agent)
    return false unless agent
    return true if everyone?

    team_member_ids.exists?(user_id: agent.id)
  end

  def includes_run?(scenario)
    return false unless scenario

    scenarios.exists?(id: scenario.run_origin.id)
  end

  def team_names
    return [] if everyone?

    Group.where(id: managed_group_ids).order(:name).pluck(:name)
  end

  private

  def managed_group_ids
    @managed_group_ids ||= @user ? GroupManager.where(user: @user).pluck(:group_id) : []
  end

  def team_member_ids
    @team_group_ids ||= managed_group_ids + Group.descendant_ids_for(managed_group_ids)
    UserGroup.where(group_id: @team_group_ids).select(:user_id)
  end
end
