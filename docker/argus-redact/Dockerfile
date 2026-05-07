# Self-contained argus-redact image for the demo stack.
# Pulls from PyPI so consumers of kong-plugin-argus-redact don't need
# to clone the upstream argus-redact source repo.

FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir 'argus-redact[serve]==0.6.4'

EXPOSE 8000

# --insecure disables Bearer auth for the self-contained demo. Production
# deployments should drop --insecure and set ARGUS_API_KEY (matched by the
# plugin's argus_api_key config); see README for examples.
CMD ["argus-redact", "serve", "--host", "0.0.0.0", "--port", "8000", "--insecure"]
