class TagsController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_can_manage_tags!, only: [:create, :destroy]

  def index
    tags = Tag.alphabetical
    render json: tags.map { |t| { id: t.id, name: t.name } }
  end

  def create
    tag = Tag.find_or_initialize_by(name: tag_params[:name].strip)
    tag.save if tag.new_record?

    if tag.persisted?
      render turbo_stream: turbo_stream.append("tag-list", partial: "tags/tag_pill", locals: { tag: tag })
    else
      head :unprocessable_entity
    end
  end

  def destroy
    tag = Tag.find(params[:id])
    tag.destroy
    render turbo_stream: turbo_stream.remove("tag_#{tag.id}")
  end

  private

  def tag_params
    params.require(:tag).permit(:name)
  end

  def ensure_can_manage_tags!
    head :forbidden unless current_user.can_manage_tags?
  end
end
