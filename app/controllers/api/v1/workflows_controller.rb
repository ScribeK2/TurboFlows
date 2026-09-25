module Api
  module V1
    class WorkflowsController < BaseController
      before_action { require_scope!(:read) }

      rescue_from Api::WorkflowCatalog::InvalidFilter do |error|
        render_error(:unprocessable_content, code: "invalid_filter", message: error.message)
      end

      def index
        filters = params.slice(:q, :tag, :group, :status, :page)
        bad = filters.keys.find { |key| !filters[key].is_a?(String) }
        if bad
          return render_error(:unprocessable_content, code: "invalid_filter", path: bad,
                                                      message: "#{bad} must be a single value.")
        end

        page = catalog.search(**filters.permit(:q, :tag, :group, :status, :page).to_h.symbolize_keys)
        render json: { workflows: page.workflows.map { catalog.summary(it) }, next_page: page.next_page }
      end

      def show
        render json: catalog.document(catalog.find(params[:id]))
      end

      private

      def catalog = @catalog ||= Api::WorkflowCatalog.new(current_user, base_url: request.base_url)
    end
  end
end
