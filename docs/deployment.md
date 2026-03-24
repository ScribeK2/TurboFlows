# Deployment

TurboFlows is deployed with [Kamal](https://kamal-deploy.org/) + Puma + PostgreSQL.

See `config/deploy.yml` for configuration details.

## Required environment variables

- `RAILS_MASTER_KEY`
- `SECRET_KEY_BASE`
- PostgreSQL credentials

## Deploy

```bash
kamal deploy
```
