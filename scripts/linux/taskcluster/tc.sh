# Decode base64 content and write to files
echo "$WORKER_ENV_VAR_KEY" | base64 --decode > /etc/taskcluster/secrets/worker_env_var_key
echo "$TC_WORKER_CERT" | base64 --decode > /etc/taskcluster/secrets/worker_livelog_tls_cert
echo "$TC_WORKER_KEY" | base64 --decode > /etc/taskcluster/secrets/worker_livelog_tls_key