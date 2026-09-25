module Api
  module V1
    # POST /api/v1/drafts: a strict-dialect document in, drafts out. Never publishes.
    class DraftsController < BaseController
      before_action { require_scope!(:draft) }

      def create
        result = draft_submission.create
        return render_errors(:unprocessable_content, result.errors, warnings: result.warnings) unless result.created?

        catalog = Api::WorkflowCatalog.new(current_user, base_url: request.base_url)
        render json: { workflows: result.workflows.map { { id: it.id, title: it.title, url: catalog.url_for(it) } },
                       warnings: result.warnings },
               status: :created
      end
    end
  end
end
