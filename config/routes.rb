Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: 'users/registrations'
  }
  root to: 'dashboard#index'

  # Mount ActionCable
  mount ActionCable.server => '/cable'

  resources :workflows do
    member do
      get :preview
      get :variables
      get :start
      post :begin_execution
      # Publishing & versioning
      post :publish
      get :versions
      # AR step persistence
      patch :sync_steps
      # Builder panel routes
      get :flow_diagram
      get :settings
      # Tag assignment
      post :add_tag
      delete :remove_tag
    end
    resource :share, only: %i[create destroy], controller: "workflows/shares"
    resource :export, only: [:show], controller: "workflows/exports" do
      get :pdf, on: :member
    end
    resources :versions, only: [:show], controller: "workflow_versions" do
      collection do
        get :diff
      end
      member do
        post :restore
      end
    end
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
  end
end
