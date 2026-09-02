class FirstRunsController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :prevent_repeats
  before_action :set_minimum_password_length
  layout "devise"

  def new
    @user = User.new
  end

  def create
    @user = FirstRun.create!(first_run_params)
    sign_in(@user)
    redirect_to root_path, notice: "Welcome! Your admin account has been created."
  rescue ActiveRecord::RecordInvalid => e
    @user = e.record
    render :new, status: :unprocessable_content
  rescue FirstRun::AlreadyCompleted
    redirect_to root_path
  end

  private

  # Mirrors DeviseController#set_minimum_password_length. Devise 5 declares the
  # length validator as `minimum: proc { password_length.min }` (validatable.rb:39),
  # so reading the validator's options gives back the Proc itself, not a number —
  # truthy, so an `|| 6` fallback never fires and the view renders the Proc. Ask
  # Devise's own config accessor instead; it is what that proc calls anyway.
  # Runs for create too, so the re-render after a failed submit still has a number.
  def set_minimum_password_length
    @minimum_password_length = User.password_length.min
  end

  def prevent_repeats
    redirect_to root_path if User.exists?
  end

  def first_run_params
    params.expect(user: %i[email password password_confirmation])
  end
end
