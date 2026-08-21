[1.0.7]
* Cap concurrent task execution at 10. Upstream defaults to 9999, which makes the memory limit
  unenforceable in principle since every task forks its own Ansible process.

[1.0.6]
* Ship /etc/ansible/ansible.cfg. Task execution uses a sanitised environment, so the temporary
  paths must come from package-owned config rather than exported variables.

[1.0.5]
* Set the Ansible target-side temporary path. Without it every module transfer failed against
  the read-only home, so any playbook gathering facts or running a real module was unreachable.

[1.0.4]
* Take ownership of the whole data volume at startup. A platform restore returns it with a
  foreign uid, which made every existing project repository unusable (git dubious ownership).

[1.0.3]
* Create $HOME/.ssh with mode 700 so outbound SSH to managed hosts can write known_hosts.

[1.0.0]
* First release, packaging Semaphore UI 2.19.8.
* PostgreSQL for storage; the database is provisioned by the platform.
* The encryption keyring is generated on first run at /app/data/keys and is never overwritten.
* Session secrets are generated once and persisted, so restarts do not sign users out.
