class DashboardController < ApplicationController
  include GroupOnboarding

  before_action :redirect_to_group_onboarding, only: :index

  def index
    @dashboard = Dashboard::DataLoader.new(current_user)

    if @dashboard.csr?
      render "dashboard/csr"
    else
      @home = Dashboard::Home.new(current_user)
      render "dashboard/home"
    end
  end
end
