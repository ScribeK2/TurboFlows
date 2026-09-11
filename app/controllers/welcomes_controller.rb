# The page a person in no group is sent to from the dashboard (spec 2026-09-11
# Q3). Joining takes effect at once and returns to the dashboard (Q12); Skip is
# Welcomes::SkipsController.
class WelcomesController < ApplicationController
  include GroupOnboarding

  before_action :ensure_offered

  def show
    @nodes = Group.tree_nodes(within: self_joinable_group_ids)
    @descriptions = Group.descriptions_by_id(self_joinable_group_ids)
  end

  def create
    join_posted_groups joined_path: root_path, retry_path: welcome_path,
                       nothing_chosen: "Choose at least one group, or skip for now."
  end

  private

  # Someone already in a group, or with nothing to join, has nothing to see here.
  def ensure_offered
    redirect_to root_path unless group_onboarding_offered?
  end
end
