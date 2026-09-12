class Admin::UsersController < Admin::BaseController
  def index
    filter = Admin::UsersFilter.new(params: filter_params).call
    @users = filter.users
    @total_count = filter.total_count
    @current_page = filter.current_page
    @total_pages = filter.total_pages
    @per_page = filter.per_page_size
    @sort = filter.sort_key
    # One tree query feeds both the bulk dialog's picker and each row's paths.
    # Global has no members, so no membership picker offers it.
    @group_nodes = Group.assignable_tree_nodes
    @group_paths = @group_nodes.to_h { [it.id, it.path] }
  end

  def show
    @user = User.find(params[:id])
    @group_nodes = Group.assignable_tree_nodes
    @group_notes = @user.user_groups.where(self_joined: true).pluck(:group_id).index_with("Joined themselves")
    @managed_groups = @user.managed_groups.order(:name)
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

    # Made from the users table row or from the user page; return to whichever.
    # With no Referer (tests, a hand-built request) this is the index.
    #
    # Same self-guard as reset_password below: the list sorts newest-first, so a
    # freshly created admin's own row is the first one on the page, and the
    # select auto-submits on change with no confirmation.
    if @user == current_user
      Rails.logger.warn "[ADMIN SECURITY] #{current_user.email} attempted to change their own role"
      redirect_back_or_to admin_users_path,
                          alert: 'You cannot change your own role. Ask another administrator to do it.'
      return
    end

    unless User::ASSIGNABLE_ROLES.include?(new_role)
      redirect_back_or_to admin_users_path, alert: 'Invalid role specified.'
      return
    end

    if @user.update(role: new_role)
      redirect_back_or_to admin_users_path, notice: "User #{@user.email} role updated to #{new_role.capitalize}."
    else
      redirect_back_or_to admin_users_path,
                          alert: "Failed to update #{@user.email}: #{@user.errors.full_messages.join(', ')}"
    end
  end

  def update_groups
    @user = User.find(params[:id])
    @user.replace_groups!(params[:group_ids])

    redirect_to admin_user_path(@user), notice: "Groups updated for #{@user.email}."
  end

  def deactivate
    @user = User.find(params[:id])

    if @user == current_user
      redirect_to admin_user_path(@user),
                  alert: 'You cannot deactivate your own account. Ask another administrator to do it.'
      return
    end

    @user.deactivate!
    Rails.logger.info "[ADMIN ACTION] #{current_user.email} deactivated #{@user.email} (ID: #{@user.id})"
    redirect_to admin_user_path(@user), notice: "#{@user.email} was deactivated and can no longer sign in."
  end

  def reactivate
    @user = User.find(params[:id])
    @user.reactivate!
    Rails.logger.info "[ADMIN ACTION] #{current_user.email} reactivated #{@user.email} (ID: #{@user.id})"
    redirect_to admin_user_path(@user), notice: "#{@user.email} was reactivated and can sign in again."
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
        # SECURITY NOTE: Temporary password is returned in the JSON response body.
        # This is admin-only (authenticated + role check) with Cache-Control: no-store.
        # Acceptable trade-off for admin UX. If email-based reset becomes available,
        # prefer that approach to avoid password transit over the wire.
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
    # Still a replace: each person ends up in exactly the groups chosen. The diff
    # only keeps a self-join's origin on a group that stays (spec 2026-09-11 Q15).
    users.each { it.replace_groups!(group_ids) }

    redirect_to admin_users_path, notice: "Groups assigned to #{users.count} user(s)."
  end

  def bulk_update_role
    new_role = params[:role]
    unless User::ASSIGNABLE_ROLES.include?(new_role)
      redirect_to admin_users_path(filter_params), alert: "Invalid role."
      return
    end
    user_ids = resolve_user_ids.excluding(current_user.id.to_s, current_user.id)
    User.where(id: user_ids).find_each { |u| u.update!(role: new_role) }
    redirect_to admin_users_path(filter_params), notice: "#{user_ids.size} user(s) updated to #{new_role}."
  end

  def bulk_deactivate
    user_ids = resolve_user_ids.excluding(current_user.id.to_s, current_user.id)
    count = 0
    User.where(id: user_ids).find_each do |u|
      u.deactivate!
      count += 1
    end
    redirect_to admin_users_path(filter_params),
                notice: "#{count} user(s) deactivated. They can no longer sign in."
  end

  private

  def user_params
    params.expect(user: [:role])
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
