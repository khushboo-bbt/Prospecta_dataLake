# PgBouncer image for POC1

Terraform (`ecr.tf`) creates the private ECR repository; it cannot build or push the image
itself. Build and push this before the ECS service (`pgbouncer.tf`) can reach a steady
state — until an image exists at the tag `pgbouncer_image_tag` points at, tasks will fail to
start with an image-pull error.

The sandbox VPC has no NAT/internet gateway (see the module README), so this build has to
happen on a machine with normal internet access (your laptop, CI) — only the *push* to ECR
goes over the private `ecr.api`/`ecr.dkr` VPC endpoints once tasks are running inside the
VPC; `docker build`/`docker push` themselves run wherever Docker is installed and can reach
Docker Hub (for the `debian:bookworm-slim` base layer) and the ECR API over the public
internet, same as any other local image build.

## Build and push

```
aws ecr get-login-password --region ap-southeast-1 \
  | docker login --username AWS --password-stdin <account_id>.dkr.ecr.ap-southeast-1.amazonaws.com

docker build -t <name_prefix>-pgbouncer:latest .

docker tag <name_prefix>-pgbouncer:latest \
  <account_id>.dkr.ecr.ap-southeast-1.amazonaws.com/<name_prefix>-pgbouncer:latest

docker push <account_id>.dkr.ecr.ap-southeast-1.amazonaws.com/<name_prefix>-pgbouncer:latest
```

`<name_prefix>` matches the module's `name_prefix` variable (default `datalake-poc1`); the
repository URL and account ID are also available from `terraform output pgbouncer_ecr_repository_url`
after the first apply.

## What the image does

`entrypoint.sh` renders `pgbouncer.ini` and `userlist.txt` from the environment/secret
values the ECS task definition injects (`DB_HOST`, `DB_PORT`, `DB_NAME`, and the two
read-only logins' username/password pairs), computing the Postgres-compatible md5 auth
hash for each user so neither plaintext password is ever written to disk. Both logins share
one pool against the replica's target database in `transaction` pooling mode.

## TLS

Redshift Federated Query always requires SSL/TLS to the external Postgres data source — not
optional, not something turned off on Redshift's side. Confirmed via testing: once the
networking/DNS path to PgBouncer was working, the query still failed with `ERROR: server
does not support SSL, but SSL was required` until PgBouncer was configured to terminate TLS.
The entrypoint generates a fresh self-signed cert/key on every container start (`client_tls_sslmode
= require` in `pgbouncer.ini`) — this only needs to satisfy "the connection is encrypted", nothing
authenticates against this cert's identity (auth is still via `userlist.txt`/password), and a
private key baked into the image or persisted anywhere would be worse for secrets hygiene with
no real benefit here.

## Non-root user

The Debian `pgbouncer` binary refuses to run as root (`FATAL PgBouncer should not run as
root` — confirmed via the actual CloudWatch logs on the first build of this image). The
Dockerfile creates/ensures a dedicated `pgbouncer` system user, owns `/etc/pgbouncer` for
it, and runs the entrypoint as that user via `USER pgbouncer` — not relying on whatever the
Debian package's postinst happens to set up by default.
