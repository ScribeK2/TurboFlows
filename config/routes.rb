Rails.application.routes.draw do
  get "healthz", to: proc { [200, {}, ["OK"]] }

  # ONCE health check — checks DB writable + job worker alive
  get "up" => "health#show"

  devise_for :users, controllers: {
    registrations: 'users/registrations',
    sessions: 'users/sessions'
  }

  resource :first_run, only: %i[new create]
  root to: 'dashboard#index'

  # Mount ActionCable
  mount ActionCable.server => '/cable'

  resources :workflows do
    resource :preview, only: [:show], controller: "workflows/previews"
    resource :variables, only: [:show], controller: "workflows/variables"
    resource :flow_diagram, only: [:show], controller: "workflows/flow_diagrams"
    resource :settings, only: [:show], controller: "workflows/settings"
    resources :versions, only: [:index], controller: "workflows/versions"
    resource :step_sync, only: [:update], controller: "workflows/step_syncs"
    resource :execution, only: %i[new create], controller: "workflows/executions"
    resource :publishing, only: [:create], controller: "workflows/publishings"
    resources :taggings, only: %i[create destroy], controller: "workflows/taggings", param: :tag_id
    resource :share, only: %i[create destroy], controller: "workflows/shares"
    resource :pin, only: %i[create destroy], controller: "workflows/pins"
    resource :export, only: [:show], controller: "workflows/exports" do
      get :pdf, on: :member
    end
    # WorkflowVersionsController handles show/diff/restore (versioned snapshots)
    get "versions/diff", to: "workflow_versions#diff", as: :diff_versions
    get "versions/:id", to: "workflow_versions#show", as: :version
    post "versions/:id/restore", to: "workflow_versions#restore", as: :restore_version
    resources :scenarios, only: %i[new create]
    resources :steps, except: [:index] do
      collection do
        post :apply_template
      end
      member do
        patch :reorder
        get :panel_edit
      end
    end
  end

  # Workflow import (collection-level, not per-workflow)
  resource :workflow_import, only: %i[new create], controller: "workflows/imports", path: "workflows/import"

  resources :tags, only: %i[index create destroy]

  # Folder management (accessible to editors/admins)
  patch 'folders/move_workflow', to: 'folders#move_workflow', as: :move_workflow_folder

  # Session heartbeat (for client-side timeout detection)
  get "session/heartbeat", to: "sessions#heartbeat", as: :session_heartbeat

  # Nav menu and search
  get "nav/menu", to: "nav#menu", as: :nav_menu
  get "nav/search_data", to: "nav#search_data", as: :nav_search_data

  resources :scenarios, only: [:show] do
    member do
      post :next_step
      get :step
      post :stop
    end
  end

  # Shared player route (no auth required)
  get "s/:share_token", to: "player#show_shared", as: :shared_player

  # Player routes (authenticated)
  get "play", to: "player#index", as: :play
  post "play/:id", to: "player#start", as: :play_workflow
  scope "player/scenarios/:id" do
    get "step", to: "player#step", as: :player_scenario_step
    post "next", to: "player#next_step", as: :player_scenario_next
    post "back", to: "player#back", as: :player_scenario_back
    get "show", to: "player#show", as: :player_scenario_show
  end

  # Admin namespace
  namespace :admin do
    root to: 'dashboard#index'
    resources :users, only: %i[index update] do
      collection do
        patch :bulk_assign_groups
        patch :bulk_update_role
        patch :bulk_deactivate
      end
      member do
        patch :update_role
        patch :update_groups
        post :reset_password
      end
    end
    resources :workflows, only: %i[index show destroy]
    resources :groups do
      patch 'folders/reorder', to: 'folders#reorder', as: :reorder_folders
      resources :folders, except: [:show]
    end
    get "analytics", to: "analytics#index", as: :analytics
    get "data_health", to: "data_health#index", as: :data_health
    post "data_health/cleanup_drafts", to: "data_health#cleanup_drafts", as: :data_health_cleanup_drafts
  end
end
