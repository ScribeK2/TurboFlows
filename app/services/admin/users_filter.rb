module Admin
  class UsersFilter
    attr_reader :params

    def initialize(params:, scope: User.all)
      @params = params.respond_to?(:to_h) ? params.to_h.symbolize_keys : params.symbolize_keys
      @scope = scope
    end

    def call
      apply_search
      apply_role_filter
      apply_group_filter
      apply_sort
      paginate
      self
    end

    def users        = @scope
    def total_count  = @total_count
    def current_page = @page_clamped || page
    def total_pages  = [(@total_count.to_f / per_page).ceil, 1].max
    def per_page_size = per_page

    private

    def apply_search
      @scope = @scope.search_by(params[:q]) if params[:q].present?
    end

    def apply_role_filter
      @scope = @scope.by_role(params[:role]) if params[:role].present?
    end

    def apply_group_filter
      @scope = @scope.by_group(params[:group]) if params[:group].present?
    end

    def apply_sort
      @scope = @scope.sorted_by(params[:sort])
    end

    def paginate
      # Count before includes to avoid issues. by_group already applies .distinct.
      @total_count = @scope.count
      @scope = @scope.includes(:groups, :workflows)
      @page_clamped = [page, total_pages].min
      @scope = @scope.limit(per_page).offset((@page_clamped - 1) * per_page)
    end

    def page
      [(params[:page].to_i), 1].max
    end

    def per_page
      size = params[:per_page].to_i
      [25, 50, 100].include?(size) ? size : 25
    end
  end
end
