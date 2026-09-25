module Api
  module V1
    module Drafts
      # POST /api/v1/drafts/validate: the validator's report, writing nothing.
      # 200 either way; the report is the answer.
      class ValidationsController < BaseController
        before_action { require_scope!(:draft) }

        def create
          render json: draft_submission.validate
        end
      end
    end
  end
end
