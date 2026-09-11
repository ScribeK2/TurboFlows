# Who is offered the welcome page's group picker, and whether they skipped it
# (spec 2026-09-11 Q2, Q3, Q10). The dashboard redirects on it and explains it,
# and the welcome page and Skip both read it, so none of them can disagree about
# who is being onboarded.
module GroupOnboarding
  extend ActiveSupport::Concern

  SKIPPED_KEY = :group_onboarding_skipped

  included do
    helper_method :group_onboarding_offered?, :self_joinable_group_ids, :awaiting_groups?
  end

  private

  def self_joinable_group_ids
    @self_joinable_group_ids ||= Group.self_joinable_ids
  end

  # current_user.awaiting_groups?, asked once per request: the dashboard's
  # redirect and its notice each want it, and each ask is a query.
  def awaiting_groups?
    return @awaiting_groups if defined?(@awaiting_groups)

    @awaiting_groups = current_user.awaiting_groups?
  end

  # In no group, and there is a group they may join. awaiting_groups? goes first
  # so someone already in a group costs no tree query.
  def group_onboarding_offered?
    awaiting_groups? && self_joinable_group_ids.any?
  end

  # Skip lasts for the session (Q3). Devise signs out with sign_out_all_scopes,
  # which resets the session, and a timeout does the same.
  def group_onboarding_skipped?
    session[SKIPPED_KEY].present?
  end

  def skip_group_onboarding!
    session[SKIPPED_KEY] = true
  end

  # Only the dashboard calls this: sign-in and sign-up both land there, and a
  # remembered session reaches it without passing through either.
  def redirect_to_group_onboarding
    redirect_to welcome_path if group_onboarding_offered? && !group_onboarding_skipped?
  end

  # Joins the groups a join form posted (Q7, Q12) and returns what to tell the
  # person, as [:notice or :alert, message]. The welcome page and My groups
  # share it; they differ in where the person goes and how the page answers.
  def join_posted_groups(nothing_chosen:)
    ids = posted_group_ids
    return [:alert, nothing_chosen] if ids.empty?

    current_user.join_groups!(ids, joinable_ids: self_joinable_group_ids)
    [:notice, "You're in #{group_paths_sentence(ids)}."]
  rescue Group::NotSelfJoinable
    [:alert, "An administrator adds people to that group."]
  end

  # A join form posts group_ids[] as a list of ids. Any other shape came from a
  # hand-built request and reads as nothing chosen, not as an error page.
  def posted_group_ids
    ids = params[:group_ids]
    ids.is_a?(Array) ? ids.grep(String).compact_blank.uniq : []
  end

  # My groups (spec 2026-09-11 Q8): memberships by path, and the joinable groups
  # this person does not already see. Administrators see every workflow whatever
  # their groups, so they get no section. One tree read feeds both lists.
  def set_my_groups
    return if current_user.admin?

    nodes = Group.tree_nodes
    @group_paths = nodes.to_h { [it.id, it.path] }
    @memberships = current_user.user_groups.to_a.sort_by { @group_paths[it.group_id].to_s.downcase }
    join_ids = self_joinable_group_ids - covered_group_ids(nodes, @memberships.map(&:group_id)).to_a
    @join_nodes = nodes.select { join_ids.include?(it.id) }
    @join_descriptions = Group.descriptions_by_id(join_ids)
  end

  # The groups a person is in and every group below them: membership covers
  # subgroups, so joining one of those adds a row that changes nothing. Nodes
  # come depth-first, so a parent is always met before its children.
  def covered_group_ids(nodes, member_ids)
    nodes.each_with_object(member_ids.to_set) { |node, covered| covered << node.id if covered.include?(node.parent_id) }
  end

  # "A and B / C" for a flash, each group by its full path, alphabetical.
  def group_paths_sentence(ids)
    Group.paths_by_id.values_at(*Array(ids).compact_blank.map(&:to_i).uniq).compact.sort_by(&:downcase).to_sentence
  end
end
