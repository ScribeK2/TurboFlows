# The interactive API reference at /api/docs: signed-in HTML rendering a
# vendored copy of the Scalar API Reference viewer against the public
# /api/v1/openapi.json document. See vendor/javascript/scalar-api-reference.js
# for the exact version, source and SHA-256 of the vendored file.
class ApiDocsController < ApplicationController
  before_action :authenticate_user!

  def show; end

  private

  # Same seam PlayerController and Admin::BaseController override: a minimal
  # full-page layout with no nav chrome, no importmap and no Stimulus.
  def resolve_layout = "api_docs"
end
