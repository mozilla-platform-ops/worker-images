#!/bin/bash

set -exv

# init helpers
function retry {
  set +e
  local n=0
  local max=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        exit 1
      fi
    }
  done
  set -e
}

# Get recent CA bundle for papertrail
retry curl -s -o /etc/papertrail-bundle.pem https://papertrailapp.com/tools/papertrail-bundle.pem
md5=`md5sum /etc/papertrail-bundle.pem | awk '{ print $1 }'`
if [ "$md5" != "1062c59e49c4585a9acfaad740a79c5d" ]; then
    echo "md5 for papertrail CA bundle does not match"
    exit -1
fi

cat << EOF > /etc/rsyslog.d/00-taskcluster.conf
\$DefaultNetstreamDriverCAFile /etc/papertrail-bundle.pem # trust these CAs
\$ActionSendStreamDriver gtls # use gtls netstream driver
\$ActionSendStreamDriverMode 1 # require TLS
\$ActionSendStreamDriverAuthMode x509/name # authenticate by hostname
\$ActionSendStreamDriverPermittedPeer *.papertrailapp.com
\$ActionResumeInterval 10
\$ActionQueueSize 100000
\$ActionQueueDiscardMark 97500
\$ActionQueueHighWaterMark 80000
\$ActionQueueType LinkedList
\$ActionQueueFileName papertrailqueue
\$ActionQueueCheckpointInterval 100
\$ActionQueueMaxDiskSpace 2g
\$ActionResumeRetryCount -1
\$ActionQueueSaveOnShutdown on
\$ActionQueueTimeoutEnqueue 10
\$ActionQueueDiscardSeverity 0
*.info @logs2.papertrailapp.com:22395
EOF
