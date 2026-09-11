# Skip for now (spec 2026-09-11 Q3): the dashboard stops sending this person to
# the welcome page until their next session.
class Welcomes::SkipsController < ApplicationController
  include GroupOnboarding

  def create
    skip_group_onboarding!
    redirect_to root_path
  end
end
