# Every script in test/load/seeds writes thousands of rows. None of them may ever
# run against production, so each one calls LoadTestSeedGuard.check! first.
#
# Two independent conditions, both required:
#   - LOAD_TEST=1 in the environment (the replica's compose file sets it), and
#   - a database host that is this machine or the replica's own Postgres, whose
#     container name was chosen so no production host shares it.
module LoadTestSeedGuard
  ALLOWED_HOSTS = [nil, "", "localhost", "127.0.0.1", "::1", "loadtest-postgres"].freeze

  def self.check!
    abort "Refusing to seed: set LOAD_TEST=1 (only the load-test replica does)." unless ENV["LOAD_TEST"] == "1"

    host = ActiveRecord::Base.connection_db_config.host
    return if ALLOWED_HOSTS.include?(host)

    abort "Refusing to seed: database host #{host.inspect} is not a load-test database " \
          "(allowed: #{ALLOWED_HOSTS.compact_blank.join(', ')})."
  end
end
