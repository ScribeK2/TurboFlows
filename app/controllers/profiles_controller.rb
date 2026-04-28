class ProfilesController < ApplicationController
  before_action :authenticate_user!

  def edit; end

  def update
    if current_user.update(profile_params)
      redirect_to edit_profile_path, notice: "Profile updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def profile_params
    params.expect(user: %i[display_name time_zone])
  end
end
