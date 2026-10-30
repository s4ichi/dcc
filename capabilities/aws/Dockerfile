# AWS credential sidecar.
# The official AWS CLI v2 image (Amazon Linux 2023) ships /usr/bin/python3, so
# a stdlib-only HTTP server runs without installing anything extra.
FROM public.ecr.aws/aws-cli/aws-cli:2.36.34

COPY server.py /server.py

# compose mounts the host's ~/.aws/config and ~/.aws/login/cache read-only under /root/.aws.
# Temporary caches the CLI writes (~/.aws/cli/cache etc.) land in the container's writable layer.
ENTRYPOINT ["python3", "/server.py"]
