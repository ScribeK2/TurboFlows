# Development

## Prerequisites

- Ruby 4.0.0+
- Bundler
- SQLite3 (development) or PostgreSQL (production)

No Node.js required — uses Rails' importmap-rails for JS and Propshaft for vanilla CSS (no build step).

## Setup

```bash
git clone https://github.com/ScribeK2/TurboFlows
cd TurboFlows
bundle install
rails db:create db:migrate db:seed
```

## Running locally

```bash
bin/dev   # starts Puma + Action Cable → http://localhost:3000
```

Sign up with any email/password (Devise). Use seeded/admin account if present in `db/seeds.rb`.

## Running tests

```bash
bin/rails test                                   # full suite
bin/rails test test/models/workflow_test.rb       # single file
bin/rails test test/models/workflow_test.rb:42    # single test by line
bin/rails test -v                                 # verbose output
```
