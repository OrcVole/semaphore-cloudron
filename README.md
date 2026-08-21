# semaphore-cloudron

Cloudron package for [Semaphore UI](https://github.com/semaphoreui/semaphore) — a web interface for
running Ansible playbooks, inventories and schedules. **Not Semaphore CI**; the name is overloaded.

| | |
|---|---|
| Upstream | `semaphoreui/semaphore` `v2.19.8` (commit `3449a04`) |
| Package version | 1.0.0 |
| Base image | `cloudron/base:5.0.0` |
| Addons | `postgresql`, `localstorage` |
| Health check | `GET /api/ping` → `200 pong` |

## Secret custody

The package **generates its own encryption keyring on first run** at `/app/data/keys/keyring.yml`
and never overwrites an existing one. Upstream's defaults are both unacceptable: an unset key is a
*silent base64 passthrough* (`util/encryption.go:19-22`) leaving private SSH keys effectively in the
clear, and the shipped compose file carries a publicly-known literal key.

**`/app/data/keys` is the irreplaceable part of the backup.** A restore that loses it leaves an
install that looks entirely healthy — the interface still lists credentials and returns 200 — while
every stored secret is undecryptable. Confirm it survived with:

    semaphore vaults check --config /run/semaphore/config.json

Each key must report `active`, not `MISSING KEY`.

## Notes for maintainers

Things that are not obvious and cost time to find:

- The runtime user's home is **read-only**, so Ansible needs `HOME`, `ANSIBLE_LOCAL_TEMP` and
  **`ANSIBLE_REMOTE_TEMP`** pointed at writable paths. The last one is separate and is the one that
  breaks module transfer; a playbook using only `debug` will not reveal it.
- Task execution uses a **sanitised environment**, so Ansible configuration must live in
  `/etc/ansible/ansible.cfg` rather than in exported variables.
- A platform **restore returns `/app/data` owned by a foreign uid**, so `start.sh` chowns the whole
  volume on every start. Without that, git refuses every existing project repository.
- The PostgreSQL port belongs **inside** `SEMAPHORE_DB_HOST` as `host:port`; there is no separate
  port variable. `sslmode=disable` is required because the addon serves no TLS.
- `password_login_disable` is **advertisement only** upstream, so this package is not SSO-only.
- Users created through single sign-on are external and never administrators; the first
  administrator must be created locally.
