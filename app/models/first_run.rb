class FirstRun
  AlreadyCompleted = Class.new(StandardError)

  def self.create!(user_params)
    # Wrap in transaction to guard against concurrent first requests
    # creating multiple admins (low-probability on corporate intranet,
    # but belt-and-suspenders).
    User.transaction do
      raise AlreadyCompleted if User.exists?
      User.create!(user_params.merge(role: "admin"))
    end
  end
end
