class MarkdownController < ApplicationController
  def preview
    html = helpers.render_step_markdown(params[:text].to_s)
    render html: html, layout: false
  end
end
