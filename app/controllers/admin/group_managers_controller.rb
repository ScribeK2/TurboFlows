# Who manages a group, set from the group's page (spec 2026-09-12). Built as the
# members card is: a search that stays open, Add per result, Remove with no
# confirm, the card streamed back whole with a flash naming who changed.
class Admin::GroupManagersController < Admin::BaseController
  SEARCH_LIMIT = 10

  before_action :set_group

  # The manager search, answered into the group page's turbo-frame.
  def index
    @query = search_query
    @candidates = candidates_for(@query)
  end

  def create
    user = User.where(deactivated_at: nil).find(params[:user_id])
    grant = @group.group_managers.build(user:)

    if grant.save
      respond_with_managers notice: "#{user.email} now manages #{@group.name}."
    else
      respond_with_managers alert: grant.errors.full_messages.to_sentence
    end
  rescue ActiveRecord::RecordNotUnique
    # Two concurrent Adds for the same person: the loser hits the DB's
    # uniqueness constraint after the validation already passed. The person
    # ends up managing the group either way, so report it as the same success.
    respond_with_managers notice: "#{user.email} now manages #{@group.name}."
  end

  def destroy
    grant = @group.group_managers.find(params[:id])
    email = grant.user.email
    grant.destroy!

    respond_with_managers notice: "#{email} no longer manages #{@group.name}."
  end

  private

  def set_group
    @group = Group.find(params[:group_id])
  end

  def search_query
    params[:q].to_s.strip
  end

  # Accounts that can sign in, match the search and do not already manage it.
  def candidates_for(query)
    return User.none if query.blank?

    User.search_by(query)
        .where(deactivated_at: nil)
        .where.not(id: @group.group_managers.select(:user_id))
        .order(:email)
        .limit(SEARCH_LIMIT)
  end

  def respond_with_managers(notice: nil, alert: nil)
    respond_to do |format|
      format.turbo_stream do
        flash.now[:notice] = notice if notice
        flash.now[:alert] = alert if alert
        @query = search_query
        @candidates = candidates_for(@query)
        render "admin/group_managers/changed"
      end
      format.html { redirect_to admin_group_path(@group), notice:, alert: }
    end
  end
end
