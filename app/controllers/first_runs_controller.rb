class FirstRunsController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :prevent_repeats
  layout "devise"

  def new
    @user = User.new
    @minimum_password_length = User.validators_on(:password)
      .detect { |v| v.is_a?(ActiveModel::Validations::LengthValidator) }
      &.options&.dig(:minimum) || 6
  end

  def create
    @user = FirstRun.create!(first_run_params)
    sign_in(@user)
    redirect_to root_path, notice: "Welcome! Your admin account has been created."
  rescue ActiveRecord::RecordInvalid => e
    @user = e.record
    render :new, status: :unprocessable_entity
  rescue FirstRun::AlreadyCompleted
    redirect_to root_path
  end

  private

  def prevent_repeats
    redirect_to root_path if User.exists?
  end

  def first_run_params
    params.require(:user).permit(:email, :password, :password_confirmation)
  end
end
