class Admin::WorkflowsController < Admin::BaseController
  def index
    filter = Admin::WorkflowsFilter.new(params: filter_params).call
    @workflows = filter.workflows
    @total_count = filter.total_count
    @current_page = filter.current_page
    @total_pages = filter.total_pages
    @per_page = filter.per_page_size
  end

  def show
    @workflow = Workflow.find(params[:id])
  end

  def destroy
    @workflow = Workflow.find(params[:id])
    @workflow.destroy
    redirect_to admin_workflows_path, notice: "Workflow '#{@workflow.title}' was successfully deleted."
  end

  private

  def filter_params
    params.permit(:page, :per_page)
  end

  helper_method :pagination_range, :filter_params

  def pagination_range(current, total)
    return (1..total).to_a if total <= 7

    pages = [1]
    pages << :gap if current > 3

    range_start = [current - 1, 2].max
    range_end = [current + 1, total - 1].min
    pages.concat((range_start..range_end).to_a)

    pages << :gap if current < total - 2
    pages << total unless pages.include?(total)
    pages
  end
end
