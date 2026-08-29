# Deployment

TurboFlows is deployed with [Kamal](https://kamal-deploy.org/) + Puma + PostgreSQL.

**`config/deploy.yml` in this repo is a template, not the live config.** Its
registry and host are still the Rails-generated placeholders, and Kamal is not
in the Gemfile, so `kamal deploy` does not run from a clean checkout. The real
Kamal config is kept outside the repo. Treat the file here as a record of
intent — anything you change in it must be mirrored into the out-of-repo config
to take effect.

## Required environment variables

- `RAILS_MASTER_KEY`
- `SECRET_KEY_BASE`
- PostgreSQL credentials

## Deploy

```bash
kamal deploy
```
