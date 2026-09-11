# Who is offered the welcome page's group picker, and whether they skipped it
# (spec 2026-09-11 Q2, Q3, Q10). The dashboard redirects on it and explains it,
# and the welcome page and Skip both read it, so none of them can disagree about
# who is being onboarded.
module GroupOnboarding
  extend ActiveSupport::Concern

  SKIPPED_KEY = :group_onboarding_skipped

  included do
    helper_method :group_onboarding_offered?, :self_joinable_group_ids
  end

  private

  def self_joinable_group_ids
    @self_joinable_group_ids ||= Group.self_joinable_ids
  end

  # In no group, and there is a group they may join. awaiting_groups? goes first
  # so someone already in a group costs no tree query.
  def group_onboarding_offered?
    current_user.awaiting_groups? && self_joinable_group_ids.any?
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

  # Joins the groups a join form posted and says which (Q7, Q12). The welcome
  # page and My groups share it; they differ only in where the person goes.
  def join_posted_groups(joined_path:, retry_path:, nothing_chosen:)
    ids = posted_group_ids
    return redirect_to(retry_path, alert: nothing_chosen) if ids.empty?

    current_user.join_groups!(ids, joinable_ids: self_joinable_group_ids)
    redirect_to joined_path, notice: "You're in #{group_paths_sentence(ids)}."
  rescue Group::NotSelfJoinable
    redirect_to retry_path, alert: "An administrator adds people to that group."
  end

  # A join form posts group_ids[] as a list of ids. Any other shape came from a
  # hand-built request and reads as nothing chosen, not as an error page.
  def posted_group_ids
    ids = params[:group_ids]
    ids.is_a?(Array) ? ids.grep(String).compact_blank.uniq : []
  end

  # "A and B / C" for a flash, each group by its full path, alphabetical.
  def group_paths_sentence(ids)
    Group.paths_by_id.values_at(*Array(ids).compact_blank.map(&:to_i).uniq).compact.sort_by(&:downcase).to_sentence
  end
end
