class Users::SessionsController < Devise::SessionsController
  def new
    redirect_to new_first_run_path and return if User.none?
    super
  end
end
