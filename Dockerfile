ARG SEMAPHORE_VERSION=v2.19.8

FROM golang:1.26.4 AS builder

# A pre-FROM ARG is a global argument and is NOT in scope inside a build stage; it has to be
# re-declared here to be visible. Without this the clone below runs with an empty --branch and fails.
ARG SEMAPHORE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends git curl && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth 1 --branch ${SEMAPHORE_VERSION} https://github.com/semaphoreui/semaphore.git .

RUN cd web && npm ci && npm run build

# Match upstream's own release build (Taskfile `build:be`): static, netgo, and the ldflags that
# inject the version. Without them the binary reports its version as `undefined-00000000-`, which
# contradicts the manifest's upstreamVersion in the interface and in any evidence table.
RUN CGO_ENABLED=0 go build -o ./bin/semaphore -tags "netgo" \
    -ldflags "-s -w -X github.com/semaphoreui/semaphore/util.Ver=${SEMAPHORE_VERSION#v} -X github.com/semaphoreui/semaphore/util.Commit=$(git log --pretty=format:'%h' -n 1) -X github.com/semaphoreui/semaphore/util.Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ./cli

FROM cloudron/base:5.0.0

RUN apt-get update && apt-get install -y --no-install-recommends ansible git && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bin/semaphore /app/code/bin/semaphore
# Semaphore executes tasks with a sanitised environment, forwarding only the variables named in
# `forwarded_env_vars`, so exporting in start.sh does not reach Ansible. Of Ansible's four config
# locations, ANSIBLE_CONFIG is stripped by that sanitiser, ./ansible.cfg lives in the user's own
# repository, and ~/.ansible.cfg is on the read-only home. That leaves /etc/ansible/ansible.cfg as
# the only place this package can put configuration and rely on it being read.
#
# remote_tmp is the one that matters: every module Ansible ships unpacks there, it defaults to
# ~/.ansible/tmp, and it is expanded from the passwd entry, which is read-only here.
RUN mkdir -p /etc/ansible && printf '%s\n' \
    '[defaults]' \
    'local_tmp = /run/semaphore/ansible-tmp' \
    'remote_tmp = /run/semaphore/ansible-remote-tmp' \
    'host_key_checking = False' \
    'retry_files_enabled = False' \
    > /etc/ansible/ansible.cfg

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

CMD [ "/app/code/start.sh" ]
