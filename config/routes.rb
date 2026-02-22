Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: 'users/registrations'
  }
  root to: 'dashboard#index'

  # Mount ActionCable
  mount ActionCable.server => '/cable'

  resources :workflows do
    collection do
      get :import
      post :import_file
      post :start_wizard
    end
    member do
      get :export
      get :export_pdf
      get :preview
      get :variables
      post :save_as_template
      get :start
      post :begin_execution
      # Wizard routes
      get :step1
      patch :update_step1
      get :step2
      patch :update_step2
      get :step3
      patch :create_from_draft
      # Step rendering for dynamic step creation (Sprint 3)
      post :render_step
    end
    resources :scenarios, only: %i[new create]
  end

  # Folder management (accessible to editors/admins)
  patch 'folders/move_workflow', to: 'folders#move_workflow', as: :move_workflow_folder

  resources :templates do
    member do
      post :use
    end
  end

  resources :scenarios, only: [:show] do
    member do
      post :next_step
      get :step
      post :stop
    end
  end

  # Admin namespace
  namespace :admin do
    root to: 'dashboard#index'
    resources :users, only: %i[index update] do
      collection do
        patch :bulk_assign_groups
      end
      member do
        patch :update_role
        patch :update_groups
        post :reset_password
      end
    end
    resources :templates, except: [:show]
    resources :workflows, only: %i[index show]
    resources :groups do
      patch 'folders/reorder', to: 'folders#reorder', as: :reorder_folders
      resources :folders, except: [:show]
    end
  end
end
