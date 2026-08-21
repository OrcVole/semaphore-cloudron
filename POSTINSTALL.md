### Signing in

Sign in as **admin** with the password shown in your app's Terminal on first start, or create an
administrator yourself:

```
semaphore user add --admin --login you --name "Your Name" \
  --email you@example.com --password '<a strong password>' \
  --config /run/semaphore/config.json
```

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
