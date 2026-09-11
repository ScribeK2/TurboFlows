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

  # "A and B / C" for a flash, each group by its full path, alphabetical.
  def group_paths_sentence(ids)
    Group.paths_by_id.values_at(*Array(ids).compact_blank.map(&:to_i)).compact.sort_by(&:downcase).to_sentence
  end
end
