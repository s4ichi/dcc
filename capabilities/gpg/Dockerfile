# GPG signing sidecar.
# The private key (only the signing key's keygrip) and the passphrase cache stay inside this container.
# The entrypoint assembles a container-local keyring, and server.py listens for the signing API
# on 127.0.0.1:8081 (netns shared with the agent container).
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends gnupg pinentry-curses python3 \
  && rm -rf /var/lib/apt/lists/*

COPY server.py /server.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY gpg-warm.sh /usr/local/bin/gpg-warm.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gpg-warm.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
