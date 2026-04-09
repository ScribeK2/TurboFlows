class WorkflowChannel < ApplicationCable::Channel
  @memory_presence_store = {}
  @presence_mutex = Mutex.new

  class << self
    attr_reader :memory_presence_store, :presence_mutex
  end

  def subscribed
    workflow = find_workflow

    if workflow.can_be_edited_by?(current_user)
      stream_from "workflow:#{workflow.id}"
      stream_from "workflow:#{workflow.id}:presence"

      add_presence(workflow)
      broadcast_presence_update(workflow, { type: "user_joined", user: user_info })
    else
      reject
    end
  end

  def unsubscribed
    workflow = Workflow.find_by(id: params[:workflow_id])
    if workflow
      remove_presence(workflow)
      broadcast_presence_update(workflow, { type: "user_left", user: user_info })
    end
  end

  # Handle title/description updates from other users
  def workflow_metadata_update(data)
    workflow = find_workflow
    return unless workflow.can_be_edited_by?(current_user)

    ActionCable.server.broadcast("workflow:#{workflow.id}", {
                                   type: "workflow_metadata_update",
                                   field: data["field"],
                                   value: data["value"],
                                   user: user_info,
                                   timestamp: Time.current.iso8601
                                 })
  end

  private

  def find_workflow
    @find_workflow ||= Workflow.find(params[:workflow_id])
  end

  def user_info
    {
      id: current_user.id,
      email: current_user.email,
      name: current_user.email.split("@").first.titleize
    }
  end

  # ==========================================================================
  # Presence Tracking
  # ==========================================================================

  def add_presence(workflow)
    presence_key = presence_redis_key(workflow)

    if redis_available?
      redis_connection.sadd(presence_key, current_user.id.to_s)
      redis_connection.expire(presence_key, 3600)
    else
      presence_mutex.synchronize do
        memory_presence_store[presence_key] ||= Set.new
        memory_presence_store[presence_key].add(current_user.id)
      end
    end
  end

  def remove_presence(workflow)
    presence_key = presence_redis_key(workflow)

    if redis_available?
      redis_connection.srem(presence_key, current_user.id.to_s)
    else
      presence_mutex.synchronize do
        memory_presence_store[presence_key]&.delete(current_user.id)
        memory_presence_store.delete(presence_key) if memory_presence_store[presence_key] && memory_presence_store[presence_key].empty?
      end
    end
  end

  def get_active_users(workflow)
    presence_key = presence_redis_key(workflow)

    user_ids = if redis_available?
                 redis_connection.smembers(presence_key).map(&:to_i)
               else
                 presence_mutex.synchronize do
                   (memory_presence_store[presence_key] || Set.new).to_a
                 end
               end

    return [] if user_ids.empty?

    User.where(id: user_ids).map do |user|
      { id: user.id, email: user.email, name: user.email.split("@").first.titleize }
    end
  end

  def redis_connection
    @redis_connection ||= begin
      pubsub = ActionCable.server.pubsub
      if pubsub.respond_to?(:redis_connection_for_subscriptions)
        pubsub.send(:redis_connection_for_subscriptions)
      elsif defined?(Redis) && ENV["REDIS_URL"].present?
        Redis.new(url: ENV.fetch("REDIS_URL", nil))
      end
    end
  end

  def redis_available?
    return false unless Rails.env.production? || ENV["REDIS_URL"].present?

    redis_connection.present?
  rescue StandardError => e
    Rails.logger.warn "Redis not available for presence tracking: #{e.message}"
    false
  end

  def presence_redis_key(workflow)
    "turboflows:presence:workflow:#{workflow.id}"
  end

  def memory_presence_store
    self.class.memory_presence_store
  end

  def presence_mutex
    self.class.presence_mutex
  end

  def broadcast_presence_update(workflow, message)
    ActionCable.server.broadcast("workflow:#{workflow.id}:presence", {
                                   **message,
                                   active_users: get_active_users(workflow),
                                   timestamp: Time.current.iso8601
                                 })
  end
end
