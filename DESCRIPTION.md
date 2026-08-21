Semaphore UI is a web interface for Ansible. It gives playbooks, inventories, repositories and
schedules a browser front end, so routine automation can be run and reviewed by people who are not
sitting at a terminal.

It is **not** Semaphore CI — the name is shared by an unrelated continuous-integration product.

* Run Ansible playbooks from a browser, with live output and a full task history
* Keep inventories, repositories and environments as first-class, versioned objects
* Store SSH keys, passwords and API tokens encrypted at rest
* Schedule recurring runs, and trigger them over a webhook or the REST interface
* Give each project its own members and permissions

This package stores credentials under an encryption keyring that it generates itself on first run,
and never ships a fixed key.
