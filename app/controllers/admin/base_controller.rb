module Admin
  class BaseController < ApplicationController
    before_action :ensure_admin!
  end
end
