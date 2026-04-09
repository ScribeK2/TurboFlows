class Admin::FoldersController < Admin::BaseController
  before_action :set_group
  before_action :set_folder, only: %i[edit update destroy]

  def index
    @folders = @group.folders.ordered
  end

  def new
    @folder = @group.folders.build
  end

  def edit; end

  def create
    @folder = @group.folders.build(folder_params)

    if @folder.save
      redirect_to admin_group_folders_path(@group), notice: "Folder '#{@folder.name}' created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @folder.update(folder_params)
      redirect_to admin_group_folders_path(@group), notice: "Folder '#{@folder.name}' updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    folder_name = @folder.name
    @folder.destroy
    redirect_to admin_group_folders_path(@group), notice: "Folder '#{folder_name}' deleted. Workflows moved to Uncategorized."
  end

  def reorder
    folder_ids = params[:folder_ids]
    return head :bad_request unless folder_ids.is_a?(Array)

    Folder.transaction do
      folder_ids.each_with_index do |id, index|
        @group.folders.where(id: id).update_all(position: index)
      end
    end

    head :ok
  end

  private

  def set_group
    @group = Group.find(params[:group_id])
  end

  def set_folder
    @folder = @group.folders.find(params[:id])
  end

  def folder_params
    params.expect(folder: %i[name description position])
  end
end
