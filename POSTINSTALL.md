### Signing in

An administrator is created for you on first run. Open a **Terminal** for this app (the `>_` button)
and read the password:

```
cat /app/data/.initial-admin
```

Sign in as `admin`, **change that password**, then promote your own account from **Team → Users**.

Accounts that sign in through Cloudron single sign-on arrive as *external* users and are never
administrators, so the `admin` account above is the way in the first time. Note also that this
application's "disable password login" setting only hides the password form — the login endpoint
keeps working — so treat the `admin` password as live and change it.

### The one thing to know about backups

Your credentials — SSH keys, passwords, API tokens — are encrypted with a keyring this app generated
for itself at **`/app/data/keys/keyring.yml`**. It is included in Cloudron's backups.

**If that file is ever lost, every stored credential becomes permanently unreadable**, and the app
will not tell you. It keeps running, the credential list still loads, and the failure only appears
when something tries to *use* a key. After any restore, confirm the keyring survived:

```
semaphore vaults check --config /run/semaphore/config.json
```

Every key must report `active`. A key reported as `MISSING KEY (cannot decrypt)` means the rows it
protects can no longer be read.

### Running playbooks

Ansible and git are installed in the container. Add a repository under a project, then a playbook
task template against it. Outbound SSH to your managed hosts uses the keys you store here.
