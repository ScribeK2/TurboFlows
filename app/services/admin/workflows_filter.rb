module Admin
  class WorkflowsFilter
    PER_PAGE_OPTIONS = [10, 25, 50].freeze
    DEFAULT_PER_PAGE = 10

    attr_reader :total_count

    def initialize(params:, scope: Workflow.all)
      @params = params.respond_to?(:to_h) ? params.to_h.symbolize_keys : params.symbolize_keys
      @scope = scope
    end

    def call
      @scope = @scope.includes(:user).order(created_at: :desc)
      paginate
      self
    end

    def workflows = @scope

    def current_page = @page_clamped || page
    def total_pages  = [(@total_count.to_f / per_page).ceil, 1].max
    def per_page_size = per_page

    private

    def paginate
      @total_count = @scope.count
      @page_clamped = [page, total_pages].min
      @scope = @scope.limit(per_page).offset((@page_clamped - 1) * per_page)
    end

    def page
      [params[:page].to_i, 1].max
    end

    def per_page
      size = params[:per_page].to_i
      PER_PAGE_OPTIONS.include?(size) ? size : DEFAULT_PER_PAGE
    end

    attr_reader :params
  end
end
