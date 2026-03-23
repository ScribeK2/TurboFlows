# Seeds file for TurboFlows

# Create demo admin user for Render deployment
admin_user = User.find_or_initialize_by(email: "admin@test.com")
if admin_user.new_record?
  admin_user.password = "TestAdmin123!"
  admin_user.password_confirmation = "TestAdmin123!"
  admin_user.role = "admin"
  admin_user.save!
  puts "Created admin user: admin@test.com"
else
  # Update existing user to ensure they're an admin (only update role, not password)
  admin_user.update!(role: "admin")
  puts "Updated user to admin: admin@test.com"
end
