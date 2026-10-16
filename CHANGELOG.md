[1.0.11]

- Base image cloudron/base 5.0.0 to 6.0.0 (Ubuntu 26.04, glibc 2.43). The Semaphore binary is built
  static (CGO disabled), so it does not depend on the base's glibc. Ansible and git now come from the
  26.04 archive.
- **Check your playbooks before updating: Ansible moves from ansible-core 2.16 to 2.20** (Ansible 9.2
  to 13.1), four core releases at once, with the Ubuntu move. The changes most likely to break an
  existing playbook:
  - managed hosts need Python 3.9 or newer (2.16 accepted 2.7 and 3.6 and up);
  - since 2.19 a `when:` or other conditional that does not evaluate to true or false is an error, not
    a warning (`allow_broken_conditionals = True` under `[defaults]` in `/etc/ansible/ansible.cfg`
    turns it back into a warning while you fix them), and only strings from trusted sources are rendered as templates;
  - `async_status` results: use the `started` and `finished` tests, not the properties as booleans.
  Upstream's porting guides for ansible-core 2.17, 2.18, 2.19 and 2.20 list everything. If a playbook
  must stay on 2.16, do not take this update until it is ported.
- git 2.43 to 2.53.
- Update Semaphore UI 2.19.12 -> 2.19.16. The only release notes published for the range cover
  2.19.16: a configurable runner check interval (`check_interval_seconds`), affecting `semaphore
  runner start` only, with no database migration and no server or web interface change. This package
  runs the server, so the option is not used here.
- Fix: the description's `<upstream>` tag no longer starts with a stray backtick.

[1.0.10]

- Update Semaphore UI 2.19.8 -> 2.19.12
- Upstream: database schema migration present in this release range; existing installs must run schema changes
- Upstream: routine features and fixes across three release chunks
- No packaging changes: auth topology, workspace layout and secrets handling unchanged; base and built images digest-pinned

[1.0.9]

- Remove the post-install checklist. Both entries were standing advice rather than one-time
  actions, so they showed as permanently outstanding on a correctly configured install. The same
  guidance is in the post-install message, which is where advice belongs.

[1.0.8]

- Create an administrator on first run and write the credential to /app/data/.initial-admin.
  Single sign-on users arrive as external non-administrators and upstream forbids non-admins from
  creating projects, so a fresh install previously had no usable account at all.

[1.0.7]

- Cap concurrent task execution at 10. Upstream defaults to 9999, which makes the memory limit
  unenforceable in principle since every task forks its own Ansible process.

[1.0.6]

- Ship /etc/ansible/ansible.cfg. Task execution uses a sanitised environment, so the temporary
  paths must come from package-owned config rather than exported variables.

[1.0.5]

- Set the Ansible target-side temporary path. Without it every module transfer failed against
  the read-only home, so any playbook gathering facts or running a real module was unreachable.

[1.0.4]

- Take ownership of the whole data volume at startup. A platform restore returns it with a
  foreign uid, which made every existing project repository unusable (git dubious ownership).

[1.0.3]

- Create $HOME/.ssh with mode 700 so outbound SSH to managed hosts can write known_hosts.

[1.0.0]

- First release, packaging Semaphore UI 2.19.8.
- PostgreSQL for storage; the database is provisioned by the platform.
- The encryption keyring is generated on first run at /app/data/keys and is never overwritten.
- Session secrets are generated once and persisted, so restarts do not sign users out.
