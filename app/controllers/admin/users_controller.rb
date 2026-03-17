class Admin::UsersController < Admin::BaseController
  def index
    filter = Admin::UsersFilter.new(params: filter_params).call
    @users = filter.users
    @total_count = filter.total_count
    @current_page = filter.current_page
    @total_pages = filter.total_pages
    @per_page = filter.per_page_size
    @all_groups = Group.order(:name)
  end

  def update
    @user = User.find(params[:id])
    if @user.update(user_params)
      redirect_to admin_users_path, notice: "User #{@user.email} was successfully updated."
    else
      redirect_to admin_users_path, alert: "Failed to update user: #{@user.errors.full_messages.join(', ')}"
    end
  end

  def update_role
    @user = User.find(params[:id])
    new_role = params[:role]

    if User::ROLES.include?(new_role)
      @user.update(role: new_role)
      redirect_to admin_users_path, notice: "User #{@user.email} role updated to #{new_role.capitalize}."
    else
      redirect_to admin_users_path, alert: 'Invalid role specified.'
    end
  end

  def update_groups
    @user = User.find(params[:id])
    group_ids = params[:group_ids] || []

    # Remove all existing group assignments
    @user.user_groups.destroy_all

    # Add new group assignments
    group_ids.each do |group_id|
      next if group_id.blank?

      @user.user_groups.create!(group_id: group_id)
    end

    redirect_to admin_users_path, notice: "Groups updated for #{@user.email}."
  end

  def reset_password
    @user = User.find(params[:id])

    # Prevent self-reset security measure
    if @user == current_user
      Rails.logger.warn "[ADMIN SECURITY] #{current_user.email} attempted to reset own password via admin interface"
      respond_to do |format|
        format.json do
          render json: {
            success: false,
            error: 'Cannot reset your own password. Use the regular password reset flow.'
          }, status: :forbidden
        end
        format.html { redirect_to admin_users_path, alert: 'Cannot reset your own password. Use the regular password reset flow.' }
      end
      return
    end

    # Skip Devise password-change email; admin sees temp password in UI (avoids
    # SMTP connection on hosts like Render where mail is not configured).
    @user.skip_password_change_notification = true

    # Generate temporary password
    temp_password = @user.generate_temporary_password

    # Log the action for security audit
    Rails.logger.info "[ADMIN ACTION] #{current_user.email} generated temporary password for #{@user.email} (ID: #{@user.id}) from IP: #{request.remote_ip}"

    # Respond with JSON for AJAX requests
    respond_to do |format|
      format.json do
        response.set_header("Cache-Control", "no-store")
        render json: {
          success: true,
          password: temp_password,
          email: @user.email,
          message: 'Temporary password generated successfully'
        }
      end
      format.html { redirect_to admin_users_path, notice: "Temporary password generated for #{@user.email}." }
    end
  end

  def bulk_assign_groups
    user_ids = params[:user_ids] || []
    group_ids = params[:group_ids] || []

    if user_ids.empty?
      redirect_to admin_users_path, alert: 'No users selected.'
      return
    end

    users = User.where(id: user_ids)
    users.each do |user|
      # Remove all existing group assignments
      user.user_groups.destroy_all

      # Add new group assignments
      group_ids.each do |group_id|
        next if group_id.blank?

        user.user_groups.create!(group_id: group_id)
      end
    end

    redirect_to admin_users_path, notice: "Groups assigned to #{users.count} user(s)."
  end

  def bulk_update_role
    new_role = params[:role]
    unless User::ROLES.include?(new_role)
      redirect_to admin_users_path(filter_params), alert: "Invalid role."
      return
    end
    user_ids = resolve_user_ids
    User.where(id: user_ids).find_each { |u| u.update!(role: new_role) }
    redirect_to admin_users_path(filter_params), notice: "#{user_ids.size} user(s) updated to #{new_role}."
  end

  def bulk_deactivate
    user_ids = resolve_user_ids
    count = 0
    User.where(id: user_ids).find_each do |u|
      u.lock_access!(send_instructions: false)
      count += 1
    end
    redirect_to admin_users_path(filter_params), notice: "#{count} user(s) deactivated."
  end

  private

  def user_params
    params.require(:user).permit(:role)
  end

  helper_method :filter_params

  def filter_params
    params.permit(:q, :role, :group, :sort, :page, :per_page)
  end

  helper_method :filter_params_without

  def filter_params_without(*keys)
    filter_params.to_h.except(*keys.map(&:to_s))
  end

  helper_method :pagination_range

  def pagination_range(current, total)
    return (1..total).to_a if total <= 7

    pages = [1]
    if current > 3
      pages << :gap
    end

    range_start = [current - 1, 2].max
    range_end = [current + 1, total - 1].min
    pages.concat((range_start..range_end).to_a)

    if current < total - 2
      pages << :gap
    end
    pages << total unless pages.include?(total)
    pages
  end

  def resolve_user_ids
    if params[:select_all_matching]
      Admin::UsersFilter.new(params: filter_params).call.users.pluck(:id)
    else
      Array(params[:user_ids])
    end
  end
end
