class Users::RegistrationsController < Devise::RegistrationsController
  before_action :redirect_to_first_run_if_no_users, only: %i[new create]

  # Override create to avoid Devise's respond_with calling user_url (route doesn't exist).
  # Devise 5+ with Turbo needs explicit redirect after sign-up.
  def create
    build_resource(sign_up_params)
    resource.save
    if resource.persisted?
      set_flash_message! :notice, :signed_up
      sign_up(resource_name, resource)
      redirect_to after_sign_up_path_for(resource)
    else
      clean_up_passwords resource
      set_minimum_password_length
      render :new, status: :unprocessable_entity
    end
  end

  # Override update to handle display_name updates without requiring current_password
  def update
    self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)

    # Check if only display_name is being updated (no password or email changes)
    update_params = account_update_params
    user_params = params[:user] || {}

    # If only display_name is present and no sensitive fields are being changed
    only_display_name = user_params.key?(:display_name) &&
                        !user_params.key?(:email) &&
                        !user_params.key?(:password) &&
                        !user_params.key?(:password_confirmation) &&
                        !user_params.key?(:current_password)

    if only_display_name
      # Update display_name without requiring current_password
      if resource.update(display_name: update_params[:display_name])
        redirect_to after_update_path_for(resource), notice: "Display name updated successfully."
      else
        render :edit
      end
    elsif update_resource(resource, account_update_params)
      # Use Devise's default update behavior (requires current_password for email/password changes)
      redirect_to after_update_path_for(resource), notice: "Account updated successfully."
    else
      render :edit
    end
  end

  protected

  # Redirect to the account page after updating settings (including password)
  def after_update_path_for(resource)
    edit_user_registration_path
  end

  # Permit parameters for account updates (including password change)
  def account_update_params
    params.expect(
      user: %i[display_name
               email
               password
               password_confirmation
               current_password]
    )
  end

  def after_sign_up_path_for(_resource)
    root_path
  end

  def after_inactive_sign_up_path_for(_resource)
    root_path
  end

  def redirect_to_first_run_if_no_users
    redirect_to new_first_run_path if User.none?
  end
end
