class DashboardController < ApplicationController
  def index
    @dashboard = Dashboard::DataLoader.new(current_user)

    if @dashboard.csr?
      render "dashboard/csr"
    else
      render "dashboard/sme"
    end
  end
end
